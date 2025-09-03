terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

#########################################################
# TAGS E VARIÁVEIS GLOBAIS
#########################################################

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

#########################################################
# MÓDULOS DE INFRAESTRUTURA BASE
#########################################################

module "vpc" {
  source       = "../../modules/vpc"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "eks" {
  source             = "../../modules/eks"
  project_name       = var.project_name
  environment        = var.environment
  cluster_name       = var.eks_cluster_name
  cluster_version    = var.eks_version
  instance_types     = var.eks_instance_types
  desired_size       = var.eks_desired_size
  min_size           = var.eks_min_size
  max_size           = var.eks_max_size

  # Conecta o EKS na VPC criada pelo módulo anterior
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  tags = local.common_tags
}

#########################################################
# AUTENTICAÇÃO & REGISTRO DE IMAGENS
#########################################################

module "cognito" {
  source       = "../../modules/cognito"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "ecr" {
  source           = "../../modules/ecr"
  project_name     = var.project_name
  environment      = var.environment
  repository_names = ["api", "frontend"]
  tags             = local.common_tags
}

#########################################################
# API GATEWAY (entrada da aplicação)
#########################################################

module "api_gateway" {
  source       = "../../modules/api-gateway"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags

  # Conecta com a rede
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Conecta com o backend (ALB do EKS)
  target_alb_listener_arn = module.eks.alb_listener_arn

  # Conecta com a segurança (Cognito)
  cognito_user_pool_endpoint  = module.cognito.user_pool_endpoint
  cognito_user_pool_client_id = module.cognito.user_pool_client_id
}

#########################################################
# GLUE CODE - Específico para o ambiente (dev)
#########################################################

# Remote state do database
data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket  = var.tf_state_bucket
    key     = "database/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
  }
}

# IRSA: Role para a app acessar secrets do RDS via OIDC do EKS
data "aws_iam_policy_document" "app_secrets" {
  statement {
    sid       = "ReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.database.outputs.rds_secret_arn]
  }
}

resource "aws_iam_policy" "app_secrets" {
  name   = "${var.project_name}-${var.environment}-app-read-rds-secret"
  policy = data.aws_iam_policy_document.app_secrets.json
}

data "aws_iam_policy_document" "app_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:app:lanchonete-app-sa"]
    }
  }
}

resource "aws_iam_role" "app_irsa" {
  name               = "${var.project_name}-${var.environment}-eks-app-secrets"
  assume_role_policy = data.aws_iam_policy_document.app_irsa_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "app_irsa_attach" {
  role       = aws_iam_role.app_irsa.name
  policy_arn = aws_iam_policy.app_secrets.arn
}
