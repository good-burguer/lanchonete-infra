#!/bin/bash
set -e

AWS_REGION="us-east-1"
TF_BUCKET="good-burger-tf-state"
TF_LOCK_TABLE="good-burger-tf-lock"

echo "=== Iniciando RDS (gb-dev-postgres) ==="
aws rds start-db-instance \
  --db-instance-identifier gb-dev-postgres \
  --region $AWS_REGION || true

echo "=== Inicializando Terraform ==="
terraform init -input=false \
  -backend-config="bucket=$TF_BUCKET" \
  -backend-config="key=infra/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$TF_LOCK_TABLE" \
  -backend-config="encrypt=true"

echo "=== Recriando Cluster EKS ==="
terraform apply -auto-approve \
  -var="aws_region=$AWS_REGION" \
  -var="tf_state_bucket=$TF_BUCKET" \
  -var="tf_lock_table=$TF_LOCK_TABLE"

echo "✅ Ambiente retomado (RDS ativo, EKS recriado)."
