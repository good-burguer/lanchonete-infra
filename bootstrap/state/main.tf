terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "local" {} # <<< local só neste bootstrap
}

provider "aws" {
  region = var.aws_region
}

# S3 para o state remoto dos demais diretórios
resource "aws_s3_bucket" "tf_state" {
  bucket = var.tf_state_bucket
  force_destroy = false
  tags = {
    Project = "Good-Burguer"
    Component = "TerraformState"
    Env = "dev"
  }
}

resource "aws_s3_bucket_versioning" "tf_state_v" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_enc" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state_pab" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# (Opcional) Só permitir TLS/HTTPS
resource "aws_s3_bucket_policy" "tf_state_tls_only" {
  bucket = aws_s3_bucket.tf_state.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid = "DenyInsecureTransport",
      Effect = "Deny",
      Principal = "*",
      Action = "s3:*",
      Resource = [
        aws_s3_bucket.tf_state.arn,
        "${aws_s3_bucket.tf_state.arn}/*"
      ],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# DynamoDB para lock do Terraform
resource "aws_dynamodb_table" "tf_lock" {
  name         = var.tf_lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = {
    Project = "Good-Burguer"
    Component = "TerraformLock"
    Env = "dev"
  }
}