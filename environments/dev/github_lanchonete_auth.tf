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
  tags = {
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
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:AttachRolePolicy",
          "iam:PassRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:TagRole",
          "iam:GetRole",
          "iam:DetachRolePolicy",
          "lambda:*",
          "apigateway:*",
          "logs:*",
          "secretsmanager:*",
          "cognito-idp:*",
          "s3:*"
        ],
        Resource = "*"
      },
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