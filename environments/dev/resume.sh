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
: "${K8S_NS_DIR:=../../k8s/namespace}"      # diretório com manifests de Namespace (aplicados sem -n)
: "${K8S_APP_DIR:=../../k8s/app}"           # diretório com manifests da aplicação (aplicados com -n app)
: "${K8S_SYS_DIR:=../../k8s/kube-system}"   # diretório com manifests do kube-system (aplicados com -n kube-system)
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
: "${APP_REPO:=lanchonete-app}"
: "${GIT_SHA:=$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
: "${APP_TAG:=${GIT_SHA}-amd64}"
: "${APP_IMAGE_URI:=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_REPO}:${APP_TAG}}"

log() { printf "\n[resume] %s\n" "$*"; }
die() { echo "[resume][erro] $*" >&2; exit 1; }

log "Imagem da aplicação (APP_IMAGE_URI): ${APP_IMAGE_URI:-<indefinida>}"

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
  -var-file="terraform.tfvars" \
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
  # 5.1) Namespace(s) (sem -n)
  if [[ -d "${K8S_NS_DIR}" ]]; then
    log "Aplicando manifests de namespace em ${K8S_NS_DIR}…"
    kubectl apply -f "${K8S_NS_DIR}"
  else
    # fallback: garante pelo menos o namespace app
    kubectl get ns app >/dev/null 2>&1 || kubectl create namespace app
  fi

  # 5.2) App (com -n app)
  if [[ -d "${K8S_APP_DIR}" ]]; then
    log "Aplicando manifests da aplicação em ${K8S_APP_DIR} (namespace app)…"
    # garante namespace app
    kubectl get ns app >/dev/null 2>&1 || kubectl create namespace app

    # 5.2.1) Renderiza e aplica o Deployment com a imagem parametrizada
    if [[ -f "${K8S_APP_DIR}/deployment.yaml" ]]; then
      log "Renderizando deployment com APP_IMAGE_URI=${APP_IMAGE_URI}…"
      APP_IMAGE_URI="${APP_IMAGE_URI}" envsubst < "${K8S_APP_DIR}/deployment.yaml" | kubectl -n app apply -f -
    else
      log "Arquivo deployment.yaml não encontrado em ${K8S_APP_DIR}."
    fi

    # 5.2.2) Aplica os demais manifests da aplicação (exceto o deployment, que já foi)
    find "${K8S_APP_DIR}" -type f -name '*.yaml' ! -name 'deployment.yaml' -print0 | xargs -0 -I{} kubectl -n app apply -f {}

    # 5.2.3) Aguarda rollout do deployment (se existir)
    if kubectl -n app get deploy lanchonete-app >/dev/null 2>&1; then
      kubectl -n app rollout status deploy/lanchonete-app || true
      kubectl -n app get deploy lanchonete-app -o=jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' || true
    fi
  else
    log "Diretório de app não encontrado: ${K8S_APP_DIR} (pulando)."
  fi

  # 5.3) kube-system (com -n kube-system)
  if [[ -d "${K8S_SYS_DIR}" ]]; then
    log "Aplicando manifests do kube-system em ${K8S_SYS_DIR}…"
    # usar server-side para lidar com aws-auth e evitar conflitos de resourceVersion
    find "${K8S_SYS_DIR}" -type f -name '*.yaml' -print0 | xargs -0 -I{} kubectl -n kube-system apply --server-side --force-conflicts -f {}
  else
    log "Diretório kube-system não encontrado: ${K8S_SYS_DIR} (pulando)."
  fi
else
  log "Aplicação dos manifests desabilitada (APPLY_APP_MANIFESTS=false)."
fi

# ====== 6) Verificações rápidas ======
log "Verificando nós do cluster…"
kubectl get nodes -o wide || true
log "Verificando namespaces básicos…"
kubectl get ns || true
kubectl -n app get deploy,svc,job,pods || true

log "✅ Ambiente retomado (EKS ativo, kubeconfig atualizado, RDS em operação)."