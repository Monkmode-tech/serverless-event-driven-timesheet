###############################################################################
# Alarms (to one ops topic) and a dashboard that puts the coursework KPIs on
# screen: p95 latency < 300 ms, event processing success, DLQ backlog = 0,
# and an estimated variable cost per 1,000 API requests.
###############################################################################

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.region

  # us-east-2 list prices (USD), October 2026. Used only for the dashboard estimate.
  price = {
    http_api_request = 0.000001
    lambda_request   = 0.0000002
    lambda_gb_second = 0.0000133334
    ddb_write_unit   = 0.000000625
    ddb_read_unit    = 0.000000125
  }
  api_memory_gb = var.api_memory_mb / 1024

  cost_per_1k = join("", [
    "1000*(m1*${local.price.http_api_request} + m2*${local.price.lambda_request} + (m3/1000)*${local.api_memory_gb}*${local.price.lambda_gb_second}",
    " + m4*${local.price.ddb_write_unit} + m5*${local.price.ddb_read_unit})/m1",
  ])
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "alerts" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

#------------------------------------------------------------------------------
# Alarms
#------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = var.dlq_names

  alarm_name          = "${var.name}-dlq-${each.key}"
  alarm_description   = "Messages in the ${each.key} dead-letter queue: an event could not be processed. See docs/runbook.md#dead-letter-queues."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = var.queue_names

  alarm_name          = "${var.name}-backlog-${each.key}"
  alarm_description   = "Oldest ${each.key} message is over 5 minutes old: the consumer is failing or falling behind."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-api-5xx"
  alarm_description   = "API server errors."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = var.api_id, Stage = "$default" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_p95" {
  alarm_name          = "${var.name}-api-p95-latency"
  alarm_description   = "API p95 latency above the 300 ms target for 3 of 5 minutes."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = var.api_id, Stage = "$default" }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "payroll_failed" {
  alarm_name          = "${var.name}-payroll-failed"
  alarm_description   = "A payroll run failed. The period is marked FAILED and can be re-run - see docs/runbook.md#payroll."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = var.state_machine_arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.function_names

  alarm_name          = "${var.name}-errors-${each.key}"
  alarm_description   = "Errors in the ${each.key} function."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

#------------------------------------------------------------------------------
# Dashboard
#------------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = local.widgets })
}

locals {
  widgets = [
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 8
      height = 6
      properties = {
        title  = "API requests and errors"
        region = local.region
        stat   = "Sum"
        period = 300
        metrics = [
          ["AWS/ApiGateway", "Count", "ApiId", var.api_id, "Stage", "$default"],
          [".", "4xx", ".", ".", ".", "."],
          [".", "5xx", ".", ".", ".", "."],
        ]
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 0
      width  = 8
      height = 6
      properties = {
        title  = "API latency (target p95 < 300 ms)"
        region = local.region
        period = 60
        metrics = [
          ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, "Stage", "$default", { stat = "p50" }],
          ["...", { stat = "p95" }],
        ]
        annotations = { horizontal = [{ label = "p95 target", value = 300 }] }
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 0
      width  = 8
      height = 6
      properties = {
        title  = "Estimated variable cost per 1,000 API requests (USD)"
        region = local.region
        view   = "singleValue"
        period = 86400
        stat   = "Sum"
        metrics = [
          [{ expression = local.cost_per_1k, label = "USD per 1k requests", id = "e1" }],
          ["AWS/ApiGateway", "Count", "ApiId", var.api_id, "Stage", "$default", { id = "m1", visible = false }],
          ["AWS/Lambda", "Invocations", "FunctionName", var.function_names["api"], { id = "m2", visible = false }],
          [".", "Duration", ".", ".", { id = "m3", visible = false }],
          ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.table_name, { id = "m4", visible = false }],
          [".", "ConsumedReadCapacityUnits", ".", ".", { id = "m5", visible = false }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 6
      width  = 8
      height = 6
      properties = {
        title  = "Event consumers: backlog and dead letters"
        region = local.region
        stat   = "Maximum"
        period = 60
        metrics = concat(
          [for k, q in var.queue_names : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q, { label = "${k} backlog" }]],
          [for k, q in var.dlq_names : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q, { label = "${k} DLQ" }]],
        )
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 6
      width  = 8
      height = 6
      properties = {
        title  = "Payroll runs"
        region = local.region
        stat   = "Sum"
        period = 3600
        metrics = [
          ["AWS/States", "ExecutionsStarted", "StateMachineArn", var.state_machine_arn],
          [".", "ExecutionsSucceeded", ".", "."],
          [".", "ExecutionsFailed", ".", "."],
        ]
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 6
      width  = 8
      height = 6
      properties = {
        title  = "Business: submissions, approvals, approval time"
        region = local.region
        period = 3600
        metrics = [
          ["Timesheet", "TimesheetSubmitted", "Service", var.function_names["api"], { stat = "Sum" }],
          [".", "TimesheetApproved", ".", ".", { stat = "Sum" }],
          [".", "TimesheetRejected", ".", ".", { stat = "Sum" }],
          [".", "ApprovalLatencySeconds", ".", ".", { stat = "p50", yAxis = "right", label = "median approval time (s)" }],
        ]
      }
    },
  ]
}
