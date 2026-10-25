###############################################################################
# Event backbone
#
#   DynamoDB Stream --Pipe (filter + transform)--> custom event bus
#        |                                             |-- rule: SUBMITTED/APPROVED/REJECTED --> notify queue --> notify Lambda
#        |                                             |-- rule: APPROVED --> ledger queue --> ledger Lambda
#        +-- failed records --> pipe DLQ               |-- rule: everything --> audit log group
#                                                      +-- archive (90 days, replayable)
#
# Transactional outbox: an event exists if and only if the DynamoDB write
# committed, so the API never has to "write then publish" (the dual-write
# problem). Only WEEK# items pass the Pipe filter - profiles (pay rates)
# never become events.
###############################################################################

data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
  consumers = {
    notify = {
      handler  = "timesheet.events.notify_handler"
      statuses = ["SUBMITTED", "APPROVED", "REJECTED"]
      desc     = "Notifies managers and employees of timesheet status changes"
    }
    ledger = {
      handler  = "timesheet.events.ledger_handler"
      statuses = ["APPROVED"]
      desc     = "Adds approved hours to per-project weekly totals (exactly once)"
    }
  }
}

#------------------------------------------------------------------------------
# Bus, archive, audit trail
#------------------------------------------------------------------------------
resource "aws_cloudwatch_event_bus" "this" {
  name = var.name
}

resource "aws_cloudwatch_event_archive" "this" {
  name             = var.name
  event_source_arn = aws_cloudwatch_event_bus.this.arn
  retention_days   = 90
  description      = "Every timesheet and payroll event; replay to rebuild a consumer's state"
}

resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/events/${var.name}-audit"
  retention_in_days = var.audit_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "audit_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "audit" {
  policy_name     = "${var.name}-audit"
  policy_document = data.aws_iam_policy_document.audit_logs.json
}

resource "aws_cloudwatch_event_rule" "audit" {
  name           = "${var.name}-audit"
  description    = "Every event on the bus, to the audit log"
  event_bus_name = aws_cloudwatch_event_bus.this.name
  event_pattern = jsonencode({
    source = [{ prefix = "timesheet." }]
  })
}

resource "aws_cloudwatch_event_target" "audit" {
  rule           = aws_cloudwatch_event_rule.audit.name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  arn            = aws_cloudwatch_log_group.audit.arn
}

#------------------------------------------------------------------------------
# Queues: one per consumer, each with a DLQ; plus DLQs for the Pipe and for
# EventBridge deliveries that fail even after retries.
#------------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  for_each = toset(concat(keys(local.consumers), ["pipe", "delivery"]))

  # 14 days to investigate and redrive.
  name                              = "${var.name}-${each.key}-dlq"
  message_retention_seconds         = 1209600
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 3600
}

resource "aws_sqs_queue" "consumer" {
  for_each = local.consumers

  # Visibility timeout = 6x the function timeout, as AWS recommends for SQS-triggered Lambdas.
  name                              = "${var.name}-${each.key}"
  visibility_timeout_seconds        = 60
  message_retention_seconds         = 345600
  receive_wait_time_seconds         = 20
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 3600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.consumers

  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.consumer[each.key].arn]
  })
}

#------------------------------------------------------------------------------
# Routing rules -> queues
#------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "consumer" {
  for_each = local.consumers

  name           = "${var.name}-${each.key}"
  description    = each.value.desc
  event_bus_name = aws_cloudwatch_event_bus.this.name
  event_pattern = jsonencode({
    source        = ["timesheet.store"]
    "detail-type" = ["TimesheetStatusChanged"]
    detail        = { status = each.value.statuses }
  })
}

resource "aws_cloudwatch_event_target" "consumer" {
  for_each = local.consumers

  rule           = aws_cloudwatch_event_rule.consumer[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  arn            = aws_sqs_queue.consumer[each.key].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 20
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq["delivery"].arn
  }
}

data "aws_iam_policy_document" "queue" {
  for_each = local.consumers

  statement {
    sid       = "EventBridgeRuleOnly"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.consumer[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.consumer[each.key].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each = local.consumers

  queue_url = aws_sqs_queue.consumer[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

data "aws_iam_policy_document" "delivery_dlq" {
  statement {
    sid       = "EventBridgeDeliveryFailures"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq["delivery"].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.consumer : r.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "delivery_dlq" {
  queue_url = aws_sqs_queue.dlq["delivery"].id
  policy    = data.aws_iam_policy_document.delivery_dlq.json
}

#------------------------------------------------------------------------------
# Notifications topic (stand-in for per-user email via SES)
#------------------------------------------------------------------------------
resource "aws_sns_topic" "notifications" {
  name              = "${var.name}-notifications"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "notifications" {
  count = var.notification_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

#------------------------------------------------------------------------------
# Consumer Lambdas
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "consumer" {
  for_each = local.consumers

  statement {
    sid       = "ConsumeOwnQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.consumer[each.key].arn]
  }

  statement {
    sid       = "ReadTimesheetsWriteMarkers"
    actions   = each.key == "ledger" ? ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"] : ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  statement {
    sid       = "UseAppKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  dynamic "statement" {
    for_each = each.key == "notify" ? [1] : []

    content {
      sid       = "PublishNotifications"
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.notifications.arn]
    }
  }
}

module "consumer" {
  source   = "../function"
  for_each = local.consumers

  name        = "${var.name}-${each.key}"
  description = each.value.desc
  handler     = each.value.handler
  zip_path    = var.zip_path
  zip_hash    = var.zip_hash
  kms_key_arn = var.kms_key_arn
  policy_json = data.aws_iam_policy_document.consumer[each.key].json

  environment = {
    TABLE_NAME              = var.table_name
    NOTIFICATIONS_TOPIC_ARN = aws_sns_topic.notifications.arn
  }
}

resource "aws_lambda_event_source_mapping" "consumer" {
  for_each = local.consumers

  event_source_arn                   = aws_sqs_queue.consumer[each.key].arn
  function_name                      = module.consumer[each.key].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 5
  }
}

#------------------------------------------------------------------------------
# The Pipe: DynamoDB Stream -> bus
#------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "pipe" {
  name              = "/aws/vendedlogs/pipes/${var.name}-outbox"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "pipe_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "pipe" {
  name               = "${var.name}-outbox-pipe"
  assume_role_policy = data.aws_iam_policy_document.pipe_assume.json
}

data "aws_iam_policy_document" "pipe" {
  statement {
    sid       = "ReadStream"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
    resources = [var.stream_arn]
  }

  statement {
    sid       = "PublishToBus"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.this.arn]
  }

  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq["pipe"].arn]
  }

  statement {
    sid       = "EncryptedStreamAndDlq"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "pipe" {
  name   = "outbox"
  role   = aws_iam_role.pipe.id
  policy = data.aws_iam_policy_document.pipe.json
}

resource "aws_pipes_pipe" "outbox" {
  name        = "${var.name}-outbox"
  description = "Transactional outbox: timesheet changes in DynamoDB become events on the bus"
  role_arn    = aws_iam_role.pipe.arn
  source      = var.stream_arn
  target      = aws_cloudwatch_event_bus.this.arn

  source_parameters {
    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT", "MODIFY"]
          dynamodb  = { Keys = { SK = { S = [{ prefix = "WEEK#" }] } } }
        })
      }
    }

    dynamodb_stream_parameters {
      starting_position                  = "LATEST"
      batch_size                         = 10
      maximum_batching_window_in_seconds = 1
      maximum_retry_attempts             = 10
      maximum_record_age_in_seconds      = 86400
      on_partial_batch_item_failure      = "AUTOMATIC_BISECT"

      dead_letter_config {
        arn = aws_sqs_queue.dlq["pipe"].arn
      }
    }
  }

  target_parameters {
    # IDs, status and version only - consumers re-read the item if they need more.
    input_template = jsonencode({
      employeeId = "<$.dynamodb.NewImage.employeeId.S>"
      weekStart  = "<$.dynamodb.NewImage.weekStart.S>"
      status     = "<$.dynamodb.NewImage.status.S>"
      version    = "<$.dynamodb.NewImage.version.N>"
      managerId  = "<$.dynamodb.NewImage.managerId.S>"
      streamId   = "<$.eventID>"
    })

    eventbridge_event_bus_parameters {
      source      = "timesheet.store"
      detail_type = "TimesheetStatusChanged"
    }
  }

  log_configuration {
    level = "ERROR"

    cloudwatch_logs_log_destination {
      log_group_arn = aws_cloudwatch_log_group.pipe.arn
    }
  }

  depends_on = [aws_iam_role_policy.pipe]
}
