output "api_url" {
  description = "HTTP API base URL."
  value       = module.api.api_url
}

output "user_pool_id" {
  description = "Cognito user pool ID (scripts/seed-users.sh creates the demo users here)."
  value       = module.identity.user_pool_id
}

output "client_id" {
  description = "Cognito app client ID."
  value       = module.identity.client_id
}

output "table_name" {
  description = "DynamoDB table."
  value       = module.data.table_name
}

output "exports_bucket" {
  description = "Payroll exports bucket."
  value       = module.data.exports_bucket
}

output "state_machine_arn" {
  description = "Payroll state machine."
  value       = module.payroll.state_machine_arn
}

output "event_bus" {
  description = "Custom event bus."
  value       = module.events.bus_name
}

output "event_archive" {
  description = "Event archive (replay source)."
  value       = module.events.archive_name
}

output "queues" {
  description = "Consumer queues and their dead-letter queues."
  value = {
    consumers = module.events.queue_names
    dlqs      = module.events.dlq_names
  }
}

output "dashboard" {
  description = "CloudWatch dashboard name."
  value       = module.observability.dashboard_name
}

output "region" {
  description = "Deployment region."
  value       = var.aws_region
}
