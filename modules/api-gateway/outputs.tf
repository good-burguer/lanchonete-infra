output "api_endpoint" {
  description = "URL para invocar a API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_id" {
  description = "ID da API Gateway."
  value       = aws_apigatewayv2_api.main.id
}