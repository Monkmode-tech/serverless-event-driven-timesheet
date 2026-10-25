output "arn" {
  description = "Function ARN."
  value       = aws_lambda_function.this.arn
}

output "name" {
  description = "Function name."
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "Invoke ARN (for API Gateway integrations)."
  value       = aws_lambda_function.this.invoke_arn
}
