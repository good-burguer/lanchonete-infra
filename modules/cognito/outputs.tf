output "user_pool_id" {
  description = "ID do Cognito User Pool."
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "ARN do Cognito User Pool (usado pelo API Gateway)."
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_client_id" {
  description = "ID do cliente do User Pool."
  value       = aws_cognito_user_pool_client.main.id
}

output "user_pool_endpoint" {
  description = "Endpoint do User Pool (usado como 'issuer' no JWT)."
  value       = aws_cognito_user_pool.main.endpoint
}