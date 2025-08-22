terraform {
  backend "s3" {
    bucket         = var.tf_state_bucket
    key            = "infra/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_lock_table
    encrypt        = true
  }
}
