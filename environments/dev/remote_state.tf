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