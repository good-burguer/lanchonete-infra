# github_lanchonete_producao.tf

# --- POLICIES ESPECÍFICAS DE PRODUÇÃO ---
resource "aws_iam_policy" "ecr_push_producao" {
  name        = "gb-dev-policy-ecr-push-producao"
  description = "Permite push de imagens para o ECR de Producao"
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

resource "aws_iam_policy" "eks_describe_producao" {
  name        = "gb-dev-policy-eks-describe-producao"
  description = "Permite descrever o cluster EKS (Producao)"
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

# --- ROLE DE PRODUÇÃO ---

data "aws_iam_policy_document" "gha_lanchonete_producao_trust" {
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
      values   = ["repo:good-burguer/lanchonete-producao:*"]
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_producao" {
  name               = "gb-dev-gha-lanchonete-producao"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_producao_trust.json
  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "producao"
  }
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_producao_ecr_attach" {
  role       = aws_iam_role.gha_lanchonete_producao.name
  policy_arn = aws_iam_policy.ecr_push_producao.arn
}

resource "aws_iam_role_policy_attachment" "gha_lanchonete_producao_eks_attach" {
  role       = aws_iam_role.gha_lanchonete_producao.name
  policy_arn = aws_iam_policy.eks_describe_producao.arn
}

resource "aws_eks_access_entry" "gha_lanchonete_producao" {
  # MUDANÇA AQUI
  cluster_name  = "gb-dev-eks"
  principal_arn = aws_iam_role.gha_lanchonete_producao.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_lanchonete_producao_admin" {
  cluster_name  = "gb-dev-eks"
  principal_arn = aws_eks_access_entry.gha_lanchonete_producao.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

resource "aws_ecr_repository" "lanchonete_producao" {
  name = "lanchonete-producao"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "producao"
  }
}

output "gha_lanchonete_producao_role_arn" {
  value = aws_iam_role.gha_lanchonete_producao.arn
}