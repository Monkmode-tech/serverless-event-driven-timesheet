###############################################################################
# Payroll: Step Functions (Standard) orchestrating three Lambdas and direct
# DynamoDB / EventBridge integrations. Standard workflows give an auditable,
# exactly-once execution history; see docs/adr/0003.
#
# Triggered weekly by EventBridge Scheduler (Monday 06:00 New York time, for
# the previous week) or on demand by HR through the API.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  tasks = {
    collect = {
      handler = "timesheet.payroll.collect_handler"
      desc    = "Payroll: find approved timesheets in the period"
    }
    calculate = {
      handler = "timesheet.payroll.calculate_handler"
      desc    = "Payroll: compute one employee's gross pay (FLSA weekly overtime)"
    }
    export = {
      handler = "timesheet.payroll.export_handler"
      desc    = "Payroll: write the encrypted CSV export"
    }
  }
}

#------------------------------------------------------------------------------
# Task Lambdas (each with only the access its step needs)
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "collect" {
  statement {
    actions   = ["dynamodb:Query"]
    resources = ["${var.table_arn}/index/GSI2"]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "calculate" {
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "export" {
  statement {
    actions   = ["dynamodb:Query"]
    resources = [var.table_arn]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${var.exports_bucket_arn}/payroll/*"]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

locals {
  task_policies = {
    collect   = data.aws_iam_policy_document.collect.json
    calculate = data.aws_iam_policy_document.calculate.json
    export    = data.aws_iam_policy_document.export.json
  }
}

module "task" {
  source   = "../function"
  for_each = local.tasks

  name            = "${var.name}-payroll-${each.key}"
  description     = each.value.desc
  handler         = each.value.handler
  zip_path        = var.zip_path
  zip_hash        = var.zip_hash
  kms_key_arn     = var.kms_key_arn
  policy_json     = local.task_policies[each.key]
  timeout_seconds = 60

  environment = {
    TABLE_NAME     = var.table_name
    EXPORTS_BUCKET = var.exports_bucket
    KMS_KEY_ARN    = var.kms_key_arn
  }
}

#------------------------------------------------------------------------------
# State machine
#------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name}-payroll"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name}-payroll-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn" {
  statement {
    sid       = "InvokeTasks"
    actions   = ["lambda:InvokeFunction"]
    resources = flatten([for m in module.task : [m.arn, "${m.arn}:*"]])
  }

  statement {
    sid       = "LockMarkPaidClose"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [var.table_arn]
  }

  statement {
    sid       = "EncryptedTable"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "PublishPayrollEvents"
    actions   = ["events:PutEvents"]
    resources = [var.bus_arn]
  }

  # Step Functions log delivery and X-Ray APIs do not support resource-level permissions.
  statement {
    sid = "LogsAndTracing"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "payroll"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_sfn_state_machine" "payroll" {
  # checkov:skip=CKV_AWS_285: Execution data is deliberately excluded from logs so pay data never reaches CloudWatch; history stays in Step Functions (90 days)
  name     = "${var.name}-payroll"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/payroll.asl.json", {
    collect_arn   = module.task["collect"].arn
    calculate_arn = module.task["calculate"].arn
    export_arn    = module.task["export"].arn
    table_name    = var.table_name
    bus_name      = var.bus_name
  })

  # ERROR level without execution data: failures are visible, pay data never is.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.sfn]
}

#------------------------------------------------------------------------------
# Weekly schedule
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-payroll-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.payroll.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-payroll"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "weekly" {
  # checkov:skip=CKV_AWS_297: The schedule's only data is {"trigger":"schedule","weeks":1}; a CMK would protect nothing
  name                         = "${var.name}-weekly-payroll"
  description                  = "Run payroll for the previous week"
  schedule_expression          = "cron(0 6 ? * MON *)"
  schedule_expression_timezone = "America/New_York"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.payroll.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ trigger = "schedule", weeks = 1 })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}
