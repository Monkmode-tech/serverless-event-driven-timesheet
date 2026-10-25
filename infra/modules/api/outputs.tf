output "api_url" {
  description = "Invoke URL of the HTTP API."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_id" {
  description = "HTTP API ID (CloudWatch dimension)."
  value       = aws_apigatewayv2_api.this.id
}

output "function_name" {
  description = "API Lambda name."
  value       = module.fn.name
}
