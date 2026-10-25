output "table_name" {
  description = "DynamoDB table name."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "DynamoDB table ARN."
  value       = aws_dynamodb_table.this.arn
}

output "stream_arn" {
  description = "DynamoDB stream ARN (source of the EventBridge Pipe)."
  value       = aws_dynamodb_table.this.stream_arn
}

output "exports_bucket" {
  description = "Exports bucket name."
  value       = aws_s3_bucket.exports.id
}

output "exports_bucket_arn" {
  description = "Exports bucket ARN."
  value       = aws_s3_bucket.exports.arn
}
