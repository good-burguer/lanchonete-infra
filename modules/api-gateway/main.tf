resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api-${var.environment}"
  protocol_type = "HTTP"
  tags          = var.tags
}

resource "aws_apigatewayv2_vpc_link" "main" {
  name        = "${var.project_name}-vpc-link-${var.environment}"
  subnet_ids  = var.private_subnet_ids
  tags        = var.tags
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  name              = "${var.project_name}-jwt-authorizer-${var.environment}"
  api_id            = aws_apigatewayv2_api.main.id
  authorizer_type   = "JWT"
  identity_sources  = ["$request.header.Authorization"] # Pega o token do cabeçalho HTTP

  jwt_configuration {
    audience = [var.cognito_user_pool_client_id]
    issuer = "https://${var.cognito_user_pool_endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "main" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY" # Aceita qualquer método (GET, POST, etc.)
  
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main.id
  
  integration_uri    = var.target_alb_listener_arn
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /{proxy+}" # Uma rota "catch-all" que pega qualquer requisição
  target    = "integrations/${aws_apigatewayv2_integration.main.id}"

  # Linka a rota com o autorizador, protegendo-a!
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default" # Um stage padrão
  auto_deploy = true
  tags        = var.tags
}