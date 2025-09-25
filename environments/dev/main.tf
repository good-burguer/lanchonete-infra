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
  tags               = { Project = "Good-Burger", Env = "dev" }
}

resource "aws_iam_role_policy_attachment" "app_irsa_attach" {
  role       = aws_iam_role.app_irsa.name
  policy_arn = aws_iam_policy.app_secrets.arn
}
<<<<<<< HEAD
=======

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
>>>>>>> bec26903ae5a448a6970ec51a7f4bd022cfebeb3
