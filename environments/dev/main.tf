terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}
provider "aws" { region = var.aws_region }

############################
# VPC mínima (dev)
############################

data "aws_availability_zones" "available" {
  state = "available"
}

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

# Internet Gateway para subnets públicas
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.gb.id
  tags = {
    Name    = "gb-dev-igw"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

# 2 subnets públicas (em 2 AZs)
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

# 2 subnets privadas (em 2 AZs)
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

# Route table pública (rota 0.0.0.0/0 para o IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.gb.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name    = "gb-dev-public-rt"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway (em uma subnet pública) + EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name    = "gb-dev-nat-eip"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name    = "gb-dev-nat"
    Project = "Good-Burger"
    Env     = "dev"
  }
  depends_on = [aws_internet_gateway.igw]
}

# Route table privada (rota 0.0.0.0/0 via NAT)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.gb.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name    = "gb-dev-private-rt"
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
# Role do Cluster EKS
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "gb-dev-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKS_VPCResourceController" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Role dos Nós (Node Group)
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "gb-dev-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
# Cluster EKS
resource "aws_eks_cluster" "this" {
  name     = var.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = [for s in aws_subnet.private : s.id]
    endpoint_private_access = true
    endpoint_public_access  = true # facilita kubectl no começo; podemos restringir depois
  }

  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKS_VPCResourceController
  ]
}
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.eks_cluster_name}-ng"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [for s in aws_subnet.private : s.id]
  version         = var.eks_version # <- garante que os nós sobem na mesma versão do cluster

  scaling_config {
    desired_size = var.eks_desired_size
    min_size     = var.eks_min_size
    max_size     = var.eks_max_size
  }

  instance_types = var.eks_instance_types
  disk_size      = 20

  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }

  depends_on = [
    aws_eks_cluster.this,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
  ]
}

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  depends_on      = [aws_eks_cluster.this]
}

# Puxa o ARN do Secret do RDS do state do repo database
data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket  = var.tf_state_bucket
    key     = "database/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
  }
}

# Locais para amarrar o IRSA ao ServiceAccount da app
locals {
  app_namespace     = "app"
  app_sa_name       = "lanchonete-app-sa"
  rds_secret_arn    = data.terraform_remote_state.database.outputs.rds_secret_arn
  oidc_provider_url = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# Policy mínima: ler apenas o Secret do RDS
data "aws_iam_policy_document" "app_secrets" {
  statement {
    sid       = "ReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.rds_secret_arn]
  }
}

resource "aws_iam_policy" "app_secrets" {
  name   = "gb-dev-app-read-rds-secret"
  policy = data.aws_iam_policy_document.app_secrets.json
}

# Role IRSA: só o SA app/lanchonete-app-sa pode assumir
data "aws_iam_policy_document" "app_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.app_namespace}:${local.app_sa_name}"]
    }
  }
}

resource "aws_iam_role" "app_irsa" {
  name               = "gb-dev-eks-app-secrets"
  assume_role_policy = data.aws_iam_policy_document.app_irsa_trust.json
  tags               = { Project = "Good-Burger", Env = "dev" }
}

resource "aws_iam_role_policy_attachment" "app_irsa_attach" {
  role       = aws_iam_role.app_irsa.name
  policy_arn = aws_iam_policy.app_secrets.arn
}

# --- OIDC provider do GitHub (token.actions.githubusercontent.com) ---
# Crie UMA vez por conta/região. Reutilizado por todas as roles de pipeline.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint do GitHub OIDC (raiz do Sigstore)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Project = "Good-Burger", Env = "dev" }
}

data "aws_iam_policy_document" "ecr_push_doc" {
  statement {
    sid     = "ECRPushPull"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:ListImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = ["*"] # pode restringir ao repo de ECR específico, se quiser
  }

  # opcional: permitir criar o repo se ainda não existir
  statement {
    sid     = "ECRCreateRepoOptional"
    actions = ["ecr:CreateRepository"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecr_push" {
  name   = "gb-dev-ecr-push"
  policy = data.aws_iam_policy_document.ecr_push_doc.json
}

# Trust policy: GitHub OIDC -> essa role
data "aws_iam_policy_document" "gha_lanchonete_app_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # O GitHub sempre envia aud=sts.amazonaws.com
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restringe a role ao repo/branch (main)
    # Formato do sub: repo:<owner>/<repo>:ref:refs/heads/<branch>
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:good-burguer/lanchonete-app:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_app" {
  name               = "gb-dev-gha-lanchonete-app"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_app_trust.json
  tags               = { Project = "Good-Burger", Env = "dev" }
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_app_ecr_attach" {
  role       = aws_iam_role.gha_lanchonete_app.name
  policy_arn = aws_iam_policy.ecr_push.arn
}

# --- Allow the GitHub Actions role to query the EKS cluster (needed for aws eks update-kubeconfig)
# Account ID of the current AWS account
data "aws_caller_identity" "current" {}

# Minimal policy to allow describing the target EKS cluster
resource "aws_iam_policy" "eks_describe" {
  name   = "gb-dev-eks-describe"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowDescribeCluster",
        Effect = "Allow",
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ],
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
      }
    ]
  })
}

# Attach the policy to the GitHub Actions role
resource "aws_iam_role_policy_attachment" "gha_lanchonete_app_eks_attach" {
  role       = aws_iam_role.gha_lanchonete_app.name
  policy_arn = aws_iam_policy.eks_describe.arn
}

output "gha_lanchonete_app_role_arn" {
  value = aws_iam_role.gha_lanchonete_app.arn
}

# Cognito
# Diretório de usuários
resource "aws_cognito_user_pool" "user_pool" {
  name = "gb-dev-user-pool"

  # Exigir que o email seja o nome de usuário e que ele seja verificado
  username_attributes = ["email"]
  auto_verified_attributes = ["email"]

  # Política de senha simples para começar
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

# O "cliente" que seu app frontend usará para se comunicar com o Cognito
resource "aws_cognito_user_pool_client" "app_client" {
  name = "gb-dev-app-client"
  user_pool_id = aws_cognito_user_pool.user_pool.id

  # Não gerar um "secret" para clientes web (SPA) é uma prática comum
  generate_secret = false

  # Fluxos de autenticação que vamos permitir
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

#Lambda
# Permissões
resource "aws_iam_role" "lambda_exec" {
  name = "gb-dev-auth-lambda-exec-role"

  # Política de confiança: permite que o serviço Lambda "assuma" esta role.
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}


# RECURSO DA FUNÇÃO LAMBDA EM SI
resource "aws_lambda_function" "auth_lambda" {
  function_name = "gb-dev-auth-lambda"
  role          = aws_iam_role.lambda_exec.arn

  # Lembre-se que o Terraform precisa encontrar este arquivo na mesma pasta
  filename         = "deployment_package.zip" 
  source_code_hash = filebase64sha256("deployment_package.zip")

  handler = "handler.lambda_handler" # nome_do_arquivo.nome_da_função
  runtime = "python3.9"
  timeout = 10

  # Bloco para passar os segredos e configurações para o código Python
  environment {
    variables = {
      # Dizemos ao código Python apenas o NOME do segredo a ser buscado
      DB_SECRET_NAME       = "gb/dev/rds/postgres"

      # As outras variáveis que o código ainda precisa
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.user_pool.id
      JWT_SECRET           = var.jwt_secret
    }
  }

  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

# Esta política permite a leitura do segredo específico do RDS
data "aws_iam_policy_document" "lambda_read_rds_secret" {
  statement {
    sid       = "AllowLambdaToReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.database.outputs.rds_secret_arn]
  }
}

resource "aws_iam_policy" "lambda_read_rds_secret" {
  name   = "gb-dev-lambda-read-rds-secret-policy"
  policy = data.aws_iam_policy_document.lambda_read_rds_secret.json
}

# Anexa a nova política à Role da nossa Lambda
resource "aws_iam_role_policy_attachment" "lambda_secrets_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_read_rds_secret.arn
}

# PERMISSÃO PARA O API GATEWAY INVOCAR A LAMBDA
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # Garante que a permissão é apenas para a nossa API específica
  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# Anexa a política básica de execução da AWS.
# Isso dá à Lambda permissão para escrever logs no CloudWatch.
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}


# API Gateway
# API REST
resource "aws_api_gateway_rest_api" "api" {
  name        = "gb-dev-api"
  description = "API Gateway para os microsserviços da Lanchonete"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# O "segurança" que usa o Cognito para validar os tokens dos usuários
resource "aws_api_gateway_authorizer" "cognito" {
  name                   = "cognito-authorizer"
  type                   = "COGNITO_USER_POOLS"
  rest_api_id            = aws_api_gateway_rest_api.api.id
  provider_arns          = [aws_cognito_user_pool.user_pool.arn]
  identity_source        = "method.request.header.Authorization" # O token virá no cabeçalho "Authorization"
}

# Recurso proxy "catch-all". O {proxy+} significa "qualquer caminho a partir daqui"
resource "aws_api_gateway_resource" "proxy" {
  path_part   = "{proxy+}"
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  rest_api_id = aws_api_gateway_rest_api.api.id
}

# Método "ANY". Significa qualquer verbo HTTP (GET, POST, PUT, DELETE, etc.)
# Note que ele continua protegido pelo nosso "segurança" do Cognito!
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  
  integration_http_method = "POST" 
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.auth_lambda.invoke_arn # A conexão acontece aqui!
}

# ATUALIZAÇÃO NECESSÁRIA: Também precisamos atualizar os "triggers" do deploy
# para que ele aponte para os novos recursos proxy.
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

# Stage (Estagio) 
resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "dev"
}
