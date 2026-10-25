output "user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_endpoint" {
  description = "Issuer endpoint (without https://)."
  value       = aws_cognito_user_pool.this.endpoint
}

output "client_id" {
  description = "App client ID (JWT audience)."
  value       = aws_cognito_user_pool_client.app.id
}
