###############################################################################
# Employee timesheet & payroll - serverless, event-driven (see docs/architecture.md)
#
#   Cognito -> HTTP API (JWT) -> api Lambda -> DynamoDB
#   DynamoDB Stream -> EventBridge Pipe -> bus -> SQS -> notify / ledger Lambdas
#   Scheduler or HR -> Step Functions payroll -> S3 encrypted CSV
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

# One deployment package for every function (pure-Python, standard library +
# the boto3 that the Lambda runtime provides).
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/.build/app.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

module "kms" {
  source = "../../modules/kms"

  name = local.name
}

module "identity" {
  source = "../../modules/identity"

  name                = local.name
  deletion_protection = var.deletion_protection
}

module "data" {
  source = "../../modules/data"

  name                = local.name
  kms_key_arn         = module.kms.key_arn
  deletion_protection = var.deletion_protection
}

module "events" {
  source = "../../modules/events"

  name               = local.name
  kms_key_arn        = module.kms.key_arn
  table_name         = module.data.table_name
  table_arn          = module.data.table_arn
  stream_arn         = module.data.stream_arn
  zip_path           = data.archive_file.app.output_path
  zip_hash           = data.archive_file.app.output_base64sha256
  notification_email = var.notification_email
}

module "payroll" {
  source = "../../modules/payroll"

  name               = local.name
  kms_key_arn        = module.kms.key_arn
  table_name         = module.data.table_name
  table_arn          = module.data.table_arn
  exports_bucket     = module.data.exports_bucket
  exports_bucket_arn = module.data.exports_bucket_arn
  bus_name           = module.events.bus_name
  bus_arn            = module.events.bus_arn
  zip_path           = data.archive_file.app.output_path
  zip_hash           = data.archive_file.app.output_base64sha256
  schedule_enabled   = var.payroll_schedule_enabled
}

module "api" {
  source = "../../modules/api"

  name                      = local.name
  kms_key_arn               = module.kms.key_arn
  table_name                = module.data.table_name
  table_arn                 = module.data.table_arn
  exports_bucket            = module.data.exports_bucket
  exports_bucket_arn        = module.data.exports_bucket_arn
  payroll_state_machine_arn = module.payroll.state_machine_arn
  user_pool_endpoint        = module.identity.user_pool_endpoint
  client_id                 = module.identity.client_id
  zip_path                  = data.archive_file.app.output_path
  zip_hash                  = data.archive_file.app.output_base64sha256
}

module "observability" {
  source = "../../modules/observability"

  name              = local.name
  kms_key_arn       = module.kms.key_arn
  alert_email       = var.alert_email
  api_id            = module.api.api_id
  table_name        = module.data.table_name
  state_machine_arn = module.payroll.state_machine_arn
  queue_names       = module.events.queue_names
  dlq_names         = module.events.dlq_names
  function_names = merge(
    { api = module.api.function_name },
    module.events.consumer_function_names,
    { for k, v in module.payroll.task_function_names : "payroll-${k}" => v },
  )
}
