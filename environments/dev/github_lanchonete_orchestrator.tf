# GitHub Actions role for lanchonete-orchestrator

data "aws_iam_policy_document" "gha_lanchonete_orchestrator_trust" {
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

    # Restringe ao repositório lanchonete-orchestrator (qualquer branch)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:good-burguer/lanchonete-orchestrator:*"]
    }
  }
}

resource "aws_iam_role" "gha_lanchonete_orchestrator" {
  name               = "gb-dev-gha-lanchonete-orchestrator"
  assume_role_policy = data.aws_iam_policy_document.gha_lanchonete_orchestrator_trust.json

  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "orchestrator"
  }
}

# Permite push de imagens para o ECR
resource "aws_iam_role_policy_attachment" "gha_lanchonete_orchestrator_ecr_attach" {
  role       = aws_iam_role.gha_lanchonete_orchestrator.name
  policy_arn = aws_iam_policy.ecr_push.arn
}

# Permite descrever o cluster EKS (kubectl, aws eks update-kubeconfig, etc.)
resource "aws_iam_role_policy_attachment" "gha_lanchonete_orchestrator_eks_attach" {
  role       = aws_iam_role.gha_lanchonete_orchestrator.name
  policy_arn = aws_iam_policy.eks_describe.arn
}

# Entrada de acesso no EKS para a role do GitHub Actions
resource "aws_eks_access_entry" "gha_lanchonete_orchestrator" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.gha_lanchonete_orchestrator.arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.this]
}

# Associa a policy de ClusterAdmin à role
resource "aws_eks_access_policy_association" "gha_lanchonete_orchestrator_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.gha_lanchonete_orchestrator.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gha_lanchonete_orchestrator]
}

output "gha_lanchonete_orchestrator_role_arn" {
  value = aws_iam_role.gha_lanchonete_orchestrator.arn
}

resource "aws_ecr_repository" "lanchonete_orchestrator" {
  name = "lanchonete-orchestrator"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project = "Good-Burguer"
    Env     = "dev"
    Service = "orchestrator"
  }
}