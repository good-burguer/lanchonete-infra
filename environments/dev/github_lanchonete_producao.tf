# github_lanchonete_producao.tf

# --- POLICIES ---
# Reusa as policies padrão já existentes no módulo/env:
# - aws_iam_policy.ecr_push
# - aws_iam_policy.eks_describe

# GitHub Actions role for lanchonete-producao

data "aws_iam_policy_document" "gha_lanchonete_producao_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # GitHub OIDC sempre manda aud=sts.amazonaws.com
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restringe ao repositório lanchonete-producao (qualquer branch)
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

# Permite push de imagens para o ECR
resource "aws_iam_role_policy_attachment" "gha_lanchonete_producao_ecr_attach" {
  role       = aws_iam_role.gha_lanchonete_producao.name
  policy_arn = aws_iam_policy.ecr_push.arn
}

# Permite descrever o cluster EKS (kubectl, aws eks update-kubeconfig, etc.)
resource "aws_iam_role_policy_attachment" "gha_lanchonete_producao_eks_attach" {
  role       = aws_iam_role.gha_lanchonete_producao.name
  policy_arn = aws_iam_policy.eks_describe.arn
}

# Entrada de acesso no EKS para a role do GitHub Actions
resource "aws_eks_access_entry" "gha_lanchonete_producao" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.gha_lanchonete_producao.arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.this]
}

# Associa a policy de ClusterAdmin à role
resource "aws_eks_access_policy_association" "gha_lanchonete_producao_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.gha_lanchonete_producao.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gha_lanchonete_producao]
}

resource "aws_ecr_repository" "lanchonete_app_producao" {
  name = "lanchonete-app-producao"

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