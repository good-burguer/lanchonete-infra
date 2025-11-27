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