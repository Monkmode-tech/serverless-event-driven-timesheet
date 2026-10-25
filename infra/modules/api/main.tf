###############################################################################
# HTTP API. Every route requires a valid Cognito access token (JWT authorizer
# at the edge); the Lambda then applies role (group) and data-level rules.
###############################################################################

locals {
  routes = toset([
    "GET /me/timesheets",
    "PUT /me/timesheets/{weekStart}",
    "GET /manager/queue",
    "POST /manager/timesheets/{employeeId}/{weekStart}/decision",
    "GET /reports/projects/{projectCode}",
    "GET /hr/employees/{employeeId}",
    "PUT /hr/employees/{employeeId}",
    "POST /hr/payroll-runs",
    "GET /hr/payroll-runs/{periodStart}",
  ])
}

data "aws_iam_policy_document" "api" {
  statement {
    sid = "TimesheetTable"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [var.table_arn, "${var.table_arn}/index/GSI1"]
  }

  statement {
    sid       = "StartPayroll"
    actions   = ["states:StartExecution"]
    resources = [var.payroll_state_machine_arn]
  }

  # Presigned download links are signed with this role, so it needs read access.
  statement {
    sid       = "PayrollExportsReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${var.exports_bucket_arn}/payroll/*"]
  }

  statement {
    sid       = "AppKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

module "fn" {
  source = "../function"

  name                 = "${var.name}-api"
  description          = "Timesheet HTTP API"
  handler              = "timesheet.api.handler"
  zip_path             = var.zip_path
  zip_hash             = var.zip_hash
  kms_key_arn          = var.kms_key_arn
  policy_json          = data.aws_iam_policy_document.api.json
  memory_mb            = 512
  reserved_concurrency = var.reserved_concurrency

  environment = {
    TABLE_NAME                = var.table_name
    PAYROLL_STATE_MACHINE_ARN = var.payroll_state_machine_arn
    EXPORTS_BUCKET            = var.exports_bucket
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  protocol_type = "HTTP"
  description   = "Employee timesheet API"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = "https://${var.user_pool_endpoint}"
    audience = [var.client_id]
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.fn.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttle_burst
    throttling_rate_limit    = var.throttle_rate
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId   = "$context.requestId"
      ip          = "$context.identity.sourceIp"
      route       = "$context.routeKey"
      status      = "$context.status"
      latencyMs   = "$context.responseLatency"
      userId      = "$context.authorizer.claims.sub"
      authError   = "$context.authorizer.error"
      integration = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = module.fn.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
