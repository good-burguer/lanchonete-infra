terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" { region = var.aws_region }

# ==============================================================================
# DATA SOURCES E LOCALS
# ==============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Puxa os outputs do state do repositório de database
data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket  = var.tf_state_bucket
    key     = "database/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
  }
}

# ==============================================================================
# VPC E REDE
# (Esta seção já estava correta e foi mantida)
# ==============================================================================

resource "aws_vpc" "gb" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name    = "gb-dev-vpc"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.gb.id
  tags = {
    Name    = "gb-dev-igw"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.gb.id
  cidr_block              = ["10.10.0.0/24", "10.10.1.0/24"][count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name    = "gb-dev-public-${count.index + 1}"
    Project = "Good-Burger"
    Env     = "dev"
    Tier    = "public"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.gb.id
  cidr_block        = ["10.10.10.0/24", "10.10.11.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name    = "gb-dev-private-${count.index + 1}"
    Project = "Good-Burger"
    Env     = "dev"
    Tier    = "private"
  }
}

# ... (Restante da configuração de rede como Route Tables e NAT Gateway) ...
# (O código de rede continua aqui, sem alterações)

# ==============================================================================
# EKS (CLUSTER KUBERNETES)
# (Esta seção já estava correta e foi mantida)
# ==============================================================================

# ... (Toda a configuração do EKS, IAM Roles para o cluster e nós, etc.) ...
# (O código do EKS continua aqui, sem alterações)

# ==============================================================================
# IAM PARA GITHUB ACTIONS (OIDC)
# ==============================================================================

# Provider OIDC para o GitHub Actions (criado uma vez por conta)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = { Project = "Good-Burger", Env = "dev" }
}

# --- Role para o CI/CD do lanchonete-app (já existente) ---
# ... (Código da gha_lanchonete_app_role continua aqui) ...

# --- Role para o CI/CD do lanchonete-auth (NOVO E CORRIGIDO) ---
data "aws_iam_policy_document" "gha_lanchonete_auth_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:good-burguer/lanchonete-auth:ref:refs/heads/*"] # Permite deploy da main e dev
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_auth" {
  name               = "gb-dev-gha-lanchonete-auth"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_auth_trust.json
  tags               = { Project = "Good-Burger", Env = "dev" }
}

data "aws_iam_policy_document" "gha_lanchonete_auth_policy_doc" {
  statement {
    sid     = "AllowLambdaUpdateAndS3Upload"
    actions = [
      "lambda:UpdateFunctionCode",
      "s3:PutObject",
      "s3:GetObject"
    ]
    resources = [
      aws_lambda_function.auth_lambda.arn,
      "${aws_s3_bucket.lambda_artifacts.arn}/*" # Permissão para o bucket de artefactos
    ]
  }
}

resource "aws_iam_policy" "gha_lanchonete_auth_policy" {
  name   = "gb-dev-gha-lanchonete-auth-policy"
  policy = data.aws_iam_policy_document.gha_lanchonete_auth_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_auth_attach" {
  role       = aws_iam_role.gha_lanchonete_auth.name
  policy_arn = aws_iam_policy.gha_lanchonete_auth_policy.arn
}

# ==============================================================================
# COGNITO
# ==============================================================================

resource "aws_cognito_user_pool" "user_pool" {
  name = "gb-dev-user-pool"
  tags = { Project = "Good-Burger", Env = "dev" }
  # ... (outras configurações do user pool) ...
}

resource "aws_cognito_user_pool_client" "app_client" {
  name         = "gb-dev-app-client"
  user_pool_id = aws_cognito_user_pool.user_pool.id
  # ... (outras configurações do client) ...
}

# ==============================================================================
# S3 BUCKET PARA ARTEFACTOS
# ==============================================================================

resource "aws_s3_bucket" "lambda_artifacts" {
  bucket = "gb-lambda-artifacts-${data.aws_caller_identity.current.account_id}"
  tags   = { Project = "Good-Burger", Env = "dev" }
}

resource "aws_s3_bucket_versioning" "lambda_artifacts_versioning" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "lambda_artifacts_pab" {
  bucket                  = aws_s3_bucket.lambda_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==============================================================================
# LAMBDA (FUNÇÃO DE AUTENTICAÇÃO)
# ==============================================================================

resource "aws_iam_role" "lambda_exec" {
  name = "gb-dev-auth-lambda-exec-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = { Project = "Good-Burger", Env = "dev" }
}

# Permissão básica para logs
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permissão para ler o segredo do banco de dados
resource "aws_iam_role_policy_attachment" "lambda_secrets_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_read_rds_secret.arn
}

resource "aws_iam_policy" "lambda_read_rds_secret" {
  name = "gb-dev-lambda-read-rds-secret-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = data.terraform_remote_state.database.outputs.rds_secret_arn
    }]
  })
}

# O RECURSO DA FUNÇÃO LAMBDA (VERSÃO FINAL E CORRETA)
resource "aws_lambda_function" "auth_lambda" {
  function_name = "gb-dev-auth-lambda"
  role          = aws_iam_role.lambda_exec.arn

  # Aponta para o artefacto no S3. O pipeline do 'lanchonete-auth' é responsável por colocar o ficheiro lá.
  s3_bucket = aws_s3_bucket.lambda_artifacts.id
  s3_key    = "lanchonete-auth/dev/deployment_package.zip"

  handler = "handler.lambda_handler"
  runtime = "python3.9"
  timeout = 10

  environment {
    variables = {
      DB_SECRET_NAME       = "gb/dev/rds/postgres"
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.user_pool.id
      JWT_SECRET           = var.jwt_secret
    }
  }

  tags = { Project = "Good-Burger", Env = "dev" }
}

# Permissão para o API Gateway invocar a Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# ==============================================================================
# API GATEWAY
# ==============================================================================

resource "aws_api_gateway_rest_api" "api" {
  name = "gb-dev-api"
  tags = { Project = "Good-Burger", Env = "dev" }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{proxy+}"
}

# MÉTODO DA API (VERSÃO FINAL E CORRETA)
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE" # <-- Rota pública para permitir o login por CPF
}

resource "aws_api_gateway_integration" "lambda_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.auth_lambda.invoke_arn
}

# DEPLOYMENT DA API (VERSÃO FINAL E CORRETA)
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode({
      resource    = jsonencode(aws_api_gateway_resource.proxy),
      method      = jsonencode(aws_api_gateway_method.proxy),
      integration = jsonencode(aws_api_gateway_integration.lambda_proxy)
    }))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "dev"
}