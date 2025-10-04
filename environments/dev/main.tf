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

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
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

    # Permite qualquer repositório e branch (temporariamente, para debug do erro de OIDC)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = ["repo:good-burguer/lanchonete-app:*"]
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

# --- Grant EKS access to the GitHub Actions role via EKS Access Entries
# Creates/maintains the access entry for the pipeline role
resource "aws_eks_access_entry" "gha" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.gha_lanchonete_app.arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.this]
}

# Associates the ClusterAdmin policy to the access entry (cluster-wide)
resource "aws_eks_access_policy_association" "gha_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.gha.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gha]
}

output "gha_lanchonete_app_role_arn" {
  value = aws_iam_role.gha_lanchonete_app.arn
}
data "aws_iam_policy_document" "gha_terraform_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:good-burguer/lanchonete-app:*",
        "repo:good-burguer/lanchonete-infra:*",
        "repo:good-burguer/lanchonete-database:*",
        "repo:good-burguer/lanchonete-auth:*"
      ]
    }
  }
}

resource "aws_iam_role" "gha_terraform" {
  name               = "gb-oidc-terraform"
  assume_role_policy = data.aws_iam_policy_document.gha_terraform_trust.json
  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_iam_role_policy_attachment" "gha_terraform_admin" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- GitHub Actions role for lanchonete-auth (Lambda + Cognito via SAM) ---
data "aws_iam_policy_document" "gha_lanchonete_auth_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:good-burguer/lanchonete-auth:*"]
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_auth" {
  name               = "gb-dev-gha-lanchonete-auth"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_auth_trust.json
  tags               = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

# Policy mínima para SAM deploy (CloudFormation, IAM, Lambda, Cognito, SecretsManager, etc.)
resource "aws_iam_policy" "gha_lanchonete_auth_policy" {
  name = "gb-dev-gha-lanchonete-auth-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "cloudformation:*",
          "iam:GetRole",
          "iam:PassRole",
          "lambda:*",
          "apigateway:*",
          "logs:*",
          "secretsmanager:*",
          "cognito-idp:*",
          "s3:*"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_auth_policy_attach" {
  role       = aws_iam_role.gha_lanchonete_auth.name
  policy_arn = aws_iam_policy.gha_lanchonete_auth_policy.arn
}

output "gha_lanchonete_auth_role_arn" {
  value = aws_iam_role.gha_lanchonete_auth.arn
}