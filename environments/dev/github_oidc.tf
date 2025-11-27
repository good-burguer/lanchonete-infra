# --- OIDC provider do GitHub (token.actions.githubusercontent.com) ---
# Crie UMA vez por conta/região. Reutilizado por todas as roles de pipeline.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint do GitHub OIDC (raiz do Sigstore)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Project = "Good-Burger", Env = "dev" }
}

# Policy compartilhada para push/pull no ECR
data "aws_iam_policy_document" "ecr_push_doc" {
  statement {
    sid = "ECRPushPull"
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
    sid       = "ECRCreateRepoOptional"
    actions   = ["ecr:CreateRepository"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecr_push" {
  name   = "gb-dev-ecr-push"
  policy = data.aws_iam_policy_document.ecr_push_doc.json
}

# --- Policy mínima para o GitHub Actions descrever o cluster EKS ---
# Account ID da conta atual
data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "eks_describe" {
  name = "gb-dev-eks-describe"
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

# --- Role genérica para Terraform via GitHub OIDC (usada por múltiplos repositórios) ---
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