###############################################################################
# One Lambda function with its own log group and least-privilege role.
# Every function in this app is Python 3.12 on arm64 (Graviton: ~20% cheaper
# per GB-second than x86) with active X-Ray tracing.
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "base" {
  source_policy_documents = [var.policy_json]

  statement {
    sid       = "OwnLogGroup"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid       = "DecryptEnvironment"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "function"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.base.json
}

resource "aws_lambda_function" "this" {
  # checkov:skip=CKV_AWS_116: Invoked synchronously (API, Step Functions) or by SQS, whose own DLQ catches failures
  # checkov:skip=CKV_AWS_117: Calls only regional AWS APIs; a VPC would add NAT/endpoint cost without reducing exposure
  # checkov:skip=CKV_AWS_272: Code signing out of scope; the zip is built from this repository by Terraform
  # checkov:skip=CKV_AWS_115: Reservation is opt-in - new accounts with a 10-execution limit cannot reserve any
  function_name    = var.name
  description      = var.description
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = var.handler
  filename         = var.zip_path
  source_code_hash = var.zip_hash
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds
  kms_key_arn      = var.kms_key_arn

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = merge({ SERVICE_NAME = var.name, LOG_LEVEL = "INFO" }, var.environment)
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.this]
}
