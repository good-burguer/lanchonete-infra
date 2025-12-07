# github_lanchonete_pedidos.tf

# --- POLICIES ESPECÍFICAS DE PEDIDOS ---
resource "aws_iam_policy" "ecr_push_pedidos" {
  name        = "gb-dev-policy-ecr-push-pedidos"
  description = "Permite push de imagens para o ECR de Pedidos"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:InitiateLayerUpload",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:GetAuthorizationToken"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "eks_describe_pedidos" {
  name        = "gb-dev-policy-eks-describe-pedidos"
  description = "Permite descrever o cluster EKS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "eks:DescribeCluster",
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

# --- ROLE DE PEDIDOS ---

data "aws_iam_policy_document" "gha_lanchonete_pedidos_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:good-burguer/lanchonete-app-pedidos:*"]
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_pedidos" {
  name               = "gb-dev-gha-lanchonete-pedidos"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_pedidos_trust.json
  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "pedidos"
  }
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_pedidos_ecr" {
  role       = aws_iam_role.gha_lanchonete_pedidos.name
  policy_arn = aws_iam_policy.ecr_push_pedidos.arn
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_pedidos_eks" {
  role       = aws_iam_role.gha_lanchonete_pedidos.name
  policy_arn = aws_iam_policy.eks_describe_pedidos.arn
}

resource "aws_eks_access_entry" "gha_lanchonete_pedidos" {
  # MUDANÇA AQUI: Referência direta ao resource do eks.tf
  cluster_name  = "gb-dev-eks" 
  principal_arn = aws_iam_role.gha_lanchonete_pedidos.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_lanchonete_pedidos_admin" {
  cluster_name  = "gb-dev-eks"
  principal_arn = aws_eks_access_entry.gha_lanchonete_pedidos.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

resource "aws_ecr_repository" "lanchonete_pedidos" {
  name = "lanchonete-pedidos"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "pedidos"
  }
}

output "gha_lanchonete_pedidos_role_arn" {
  value = aws_iam_role.gha_lanchonete_pedidos.arn
}