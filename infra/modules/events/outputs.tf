output "bus_name" {
  description = "Custom event bus name."
  value       = aws_cloudwatch_event_bus.this.name
}

output "bus_arn" {
  description = "Custom event bus ARN."
  value       = aws_cloudwatch_event_bus.this.arn
}

output "queue_names" {
  description = "Consumer queue names by consumer."
  value       = { for k, q in aws_sqs_queue.consumer : k => q.name }
}

output "dlq_names" {
  description = "Dead-letter queue names (notify, ledger, pipe, delivery)."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.name }
}

output "consumer_function_names" {
  description = "Consumer Lambda names."
  value       = { for k, m in module.consumer : k => m.name }
}

output "pipe_name" {
  description = "EventBridge Pipe name."
  value       = aws_pipes_pipe.outbox.name
}

output "archive_name" {
  description = "Event archive (for replays)."
  value       = aws_cloudwatch_event_archive.this.name
}

output "audit_log_group" {
  description = "Event audit log group."
  value       = aws_cloudwatch_log_group.audit.name
}
