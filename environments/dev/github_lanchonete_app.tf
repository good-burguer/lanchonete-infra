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
      values   = ["repo:good-burguer/lanchonete-app:*"]
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