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

#!/usr/bin/env bash
set -euo pipefail

# ====== Config ======
AWS_REGION="us-east-1"
TF_BUCKET="good-burger-tf-state"
TF_LOCK_TABLE="good-burger-tf-lock"

log() { printf "\n[resume] %s\n" "$*"; }
die() { echo "[resume][erro] $*" >&2; exit 1; }

# ====== 1) RDS: iniciar se estiver parado ======
log "Verificando estado do RDS (gb-dev-postgres)…"
DB_STATUS="$(aws rds describe-db-instances \
  --db-instance-identifier gb-dev-postgres \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo 'unknown')"

case "$DB_STATUS" in
  stopped)
    log "RDS está 'stopped'. Iniciando…"
    aws rds start-db-instance \
      --db-instance-identifier gb-dev-postgres \
      --region "$AWS_REGION" >/dev/null
    log "Aguardando RDS ficar 'available'… (pode levar alguns minutos)"
    aws rds wait db-instance-available \
      --db-instance-identifier gb-dev-postgres \
      --region "$AWS_REGION"
    ;;
  available)
    log "RDS já está 'available'."
    ;;
  *)
    log "Estado do RDS: $DB_STATUS (seguindo adiante)."
    ;;
esac

# ====== 2) Terraform init (reconfigure backend) ======
log "Inicializando Terraform com backend S3 + DynamoDB…"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="key=infra/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
  -backend-config="encrypt=true"

# ====== 3) Terraform apply: recriar/conciliar EKS e dependências ======
log "Aplicando Terraform (pode demorar)…"
terraform apply -auto-approve -lock-timeout=5m \
  -var="aws_region=${AWS_REGION}" \
  -var="tf_state_bucket=${TF_BUCKET}" \
  -var="tf_lock_table=${TF_LOCK_TABLE}"

# ====== 4) kubeconfig e checagens rápidas ======
EKS_NAME="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
if [[ -n "${EKS_NAME}" ]]; then
  log "Atualizando kubeconfig para o cluster ${EKS_NAME}…"
  aws eks update-kubeconfig --name "${EKS_NAME}" --region "${AWS_REGION}" --alias "${EKS_NAME}" >/dev/null || \
    die "Falha ao atualizar kubeconfig"

  log "Nodes do cluster:"
  kubectl get nodes -o wide || true

  log "Addons do EKS:"
  aws eks list-addons --cluster-name "${EKS_NAME}" --region "${AWS_REGION}" || true
else
  log "Output 'eks_cluster_name' não encontrado. Verifique os outputs do Terraform."
fi

log "✅ Ambiente retomado (RDS pronto, EKS ativo)."