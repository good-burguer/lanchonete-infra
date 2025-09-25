#!/usr/bin/env bash
set -euo pipefail

# ====== Config (permite override por variável de ambiente) ======
: "${AWS_REGION:=us-east-1}"
: "${TF_BUCKET:=good-burger-tf-state}"
: "${TF_LOCK_TABLE:=good-burger-tf-lock}"
: "${TF_KEY:=infra/terraform.tfstate}"
: "${EKS_NAME:=gb-dev-eks}"                 # fallback caso não haja output no state
: "${EKS_NODEGROUP:=gb-dev-eks-ng}"         # nome padrão do nodegroup
: "${APPLY_APP_MANIFESTS:=true}"           # se "true", aplica k8s/app/ após recriar o cluster
: "${K8S_DIR:=../../k8s/app}"               # caminho (relativo a este script) dos manifests da app

log() { printf "\n[resume] %s\n" "$*"; }
die() { echo "[resume][erro] $*" >&2; exit 1; }

# ====== 0) Terraform init (sempre reconfigure backend S3 + DynamoDB) ======
log "Inicializando Terraform com backend S3 + DynamoDB…"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="key=${TF_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
  -backend-config="encrypt=true"

# ====== 1) Terraform apply para (re)criar EKS e dependências declaradas ======
log "Executando 'terraform apply' para (re)criar o cluster e node group…"
terraform apply -auto-approve -lock-timeout=5m \
  -var="aws_region=${AWS_REGION}" \
  -var="tf_state_bucket=${TF_BUCKET}" \
  -var="tf_lock_table=${TF_LOCK_TABLE}"

# Tenta ler nome do cluster pelo output (se existir)
TF_EKS_OUTPUT="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
if [[ -n "${TF_EKS_OUTPUT}" ]]; then
  EKS_NAME="${TF_EKS_OUTPUT}"
fi

# ====== 2) Espera EKS ficar ACTIVE e kubeconfig atualizado ======
log "Aguardando EKS ficar ACTIVE… (${EKS_NAME})"
aws eks wait cluster-active --name "${EKS_NAME}" --region "${AWS_REGION}" || true

log "Atualizando kubeconfig local para o cluster ${EKS_NAME}…"
aws eks update-kubeconfig --name "${EKS_NAME}" --region "${AWS_REGION}" >/dev/null

# ====== 3) Espera NodeGroup ficar ACTIVE (se existir) ======
if aws eks describe-nodegroup \
      --cluster-name "${EKS_NAME}" \
      --nodegroup-name "${EKS_NODEGROUP}" \
      --region "${AWS_REGION}" >/dev/null 2>&1; then
  NG_STATUS="$(aws eks describe-nodegroup \
    --cluster-name "${EKS_NAME}" \
    --nodegroup-name "${EKS_NODEGROUP}" \
    --region "${AWS_REGION}" \
    --query 'nodegroup.status' --output text)"
  log "NodeGroup ${EKS_NODEGROUP} status atual: ${NG_STATUS}. Aguardando ACTIVE…"
  aws eks wait nodegroup-active \
    --cluster-name "${EKS_NAME}" \
    --nodegroup-name "${EKS_NODEGROUP}" \
    --region "${AWS_REGION}" || true
else
  log "NodeGroup ${EKS_NODEGROUP} não encontrado (pode não ser gerenciado por este Terraform)."
fi

# ====== 4) Iniciar RDS se estiver parado ======
log "Verificando estado do RDS (gb-dev-postgres)…"
DB_STATUS="$(aws rds describe-db-instances \
  --db-instance-identifier gb-dev-postgres \
  --region "${AWS_REGION}" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo 'unknown')"

case "$DB_STATUS" in
  stopped)
    log "RDS está 'stopped'. Iniciando instância…"
    aws rds start-db-instance \
      --db-instance-identifier gb-dev-postgres \
      --region "${AWS_REGION}" >/dev/null || true
    log "Aguardando RDS ficar 'available'…"
    aws rds wait db-instance-available \
      --db-instance-identifier gb-dev-postgres \
      --region "${AWS_REGION}" || true
    ;;
  starting|available|backing-up|modifying)
    log "RDS já está em '${DB_STATUS}'."
    ;;
  *)
    log "Estado do RDS: ${DB_STATUS} (seguindo adiante)."
    ;;
esac

# ====== 5) (Opcional) Aplicar manifests da aplicação ======
if [[ "${APPLY_APP_MANIFESTS}" == "true" ]]; then
  log "Aplicando manifests de aplicação em ${K8S_DIR}…"
  # Garante namespace
  kubectl get ns app >/dev/null 2>&1 || kubectl create namespace app
  # Aplica diretório
  kubectl -n app apply -f "${K8S_DIR}"
else
  log "Aplicação dos manifests desabilitada (APPLY_APP_MANIFESTS=false)."
fi

# ====== 6) Verificações rápidas ======
log "Verificando nós do cluster…"
kubectl get nodes -o wide || true
log "Verificando namespaces básicos…"
kubectl get ns || true

log "✅ Ambiente retomado (EKS ativo, kubeconfig atualizado, RDS em operação)."