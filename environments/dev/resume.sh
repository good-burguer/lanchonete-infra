#!/usr/bin/env bash

set -euo pipefail

# Logging and error functions (must be defined before first use)
log() { printf "\n[resume] %s\n" "$*"; }
die() { echo "[resume][erro] $*" >&2; exit 1; }

# ====== Config (permite override por variável de ambiente) ======
: "${AWS_REGION:=us-east-1}"
: "${TF_BUCKET:=good-burger-tf-state}"
: "${TF_LOCK_TABLE:=good-burger-tf-lock}"
: "${TF_KEY:=infra/terraform.tfstate}"
: "${EKS_NAME:=gb-dev-eks}"                 # fallback caso não haja output no state
: "${EKS_NODEGROUP:=gb-dev-eks-ng}"         # nome padrão do nodegroup
: "${APPLY_APP_MANIFESTS:=true}"            # se "true", aplica k8s/ após recriar o cluster
: "${K8S_NS_DIR:=../../k8s/namespace}"      # diretório com manifests de Namespace (aplicados sem -n)
: "${K8S_APP_DIR:=../../k8s/app}"           # diretório com manifests do monolito (aplicados com -n app)
: "${K8S_SYS_DIR:=../../k8s/kube-system}"   # diretório com manifests do kube-system (aplicados com -n kube-system)
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"

# Monolito (legacy) — DESABILITADO (não aplicamos mais imagem/manifests do monolito por este script)
: "${APP_REPO:=lanchonete-app}"            # mantido apenas por compatibilidade (não é usado)
: "${USE_MONOLITH:=false}"                 # mantido apenas por compatibilidade (não é usado)

# Se "true", aplica também pedidos/producao/pagamento/orchestrator
: "${APPLY_ALL_SERVICES:=false}"

# Diretórios (repos irmãos) com manifests de cada serviço
# Objetivo: detectar automaticamente a raiz do workspace "good-burguer" (onde ficam lanchonete-infra, lanchonete-orchestrator, etc)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_repo_root() {
  local base="${SCRIPT_DIR}"
  local candidate

  # Tentativas: subir 1..8 níveis e validar pela presença dos diretórios esperados
  for up in 1 2 3 4 5 6 7 8; do
    candidate="${base}"
    for _ in $(seq 1 ${up}); do
      candidate="$(cd "${candidate}/.." && pwd)"
    done

    # Critério: o root deve conter lanchonete-infra e lanchonete-orchestrator (bem estável no seu repo)
    if [[ -d "${candidate}/lanchonete-infra" && -d "${candidate}/lanchonete-orchestrator" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  # Fallback: 4 níveis acima (comportamento antigo)
  echo "$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
}

: "${REPO_ROOT:=$(detect_repo_root)}"
log "REPO_ROOT detectado: ${REPO_ROOT}"

# Esperado (no mesmo nível do lanchonete-infra): lanchonete-app-pedidos, lanchonete-producao, lanchonete-app-pagamento, lanchonete-orchestrator
: "${PEDIDOS_DIR:=${REPO_ROOT}/lanchonete-app-pedidos}"
: "${PRODUCAO_DIR:=${REPO_ROOT}/lanchonete-producao}"
: "${PAGAMENTO_DIR:=${REPO_ROOT}/lanchonete-app-pagamento}"
: "${ORCHESTRATOR_DIR:=${REPO_ROOT}/lanchonete-orchestrator}"

# ECR repositories (um por serviço)
: "${ECR_PEDIDOS_REPO:=lanchonete-app-pedidos}"
: "${ECR_PRODUCAO_REPO:=lanchonete-app-producao}"
: "${ECR_PAGAMENTO_REPO:=lanchonete-app-pagamento}"
: "${ECR_ORCHESTRATOR_REPO:=lanchonete-orchestrator}"

# Nomes dos deployments no K8s
: "${DEPLOY_PEDIDOS:=lanchonete-pedidos}"
: "${DEPLOY_PRODUCAO:=lanchonete-producao}"
: "${DEPLOY_PAGAMENTO:=lanchonete-pagamento}"
: "${DEPLOY_ORCHESTRATOR:=lanchonete-orchestrator}"

# LoadBalancer do ambiente (idealmente no Orchestrator)
: "${LB_NAMESPACE:=app}"                         # namespace onde está o Service do LB
: "${LB_SERVICE_NAME:=lanchonete-orchestrator-lb}"   # nome do Service (tipo LoadBalancer)
: "${LB_WAIT_TIMEOUT:=300}"                      # tempo máximo (segundos) para aparecer o endpoint


ecr_latest_tag() {
  # args: repo_name, optional regex filter
  local repo="$1"; local regex="${2:-}"; local tag

  tag=$(aws ecr describe-images \
    --repository-name "${repo}" \
    --region "${AWS_REGION}" \
    --query 'reverse(sort_by(imageDetails[?imageTags], & imagePushedAt))[0].imageTags[0]' \
    --output text 2>/dev/null | tr -d '\n\r')

  if [[ -z "${tag}" || "${tag}" == "None" ]]; then
    echo ""
    return 0
  fi

  if [[ -n "${regex}" ]]; then
    # se não bater no regex, tenta achar a primeira tag que bate
    if ! echo "${tag}" | grep -Eq "${regex}"; then
      tag=$(aws ecr list-images \
        --repository-name "${repo}" \
        --region "${AWS_REGION}" \
        --query 'imageIds[].imageTag' \
        --output text | tr '\t' '\n' | grep -v None | grep -E "${regex}" | tail -n1 || true)
    fi
  fi

  echo "${tag}"
}

mk_image_uri() {
  # args: repo_name, tag
  local repo="$1"; local tag="$2"
  echo "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${repo}:${tag}"
}

deploy_k8s_dir() {
  # args: svc_name, repo_dir, ecr_repo, deploy_name
  local svc="$1"; local dir="$2"; local ecr_repo="$3"; local deploy_name="$4"
  local k8s_dir="${dir}/k8s"

  if [[ ! -d "${k8s_dir}" ]]; then
    log "⚠️  ${svc}: diretório k8s não encontrado em ${k8s_dir} (pulando)."
    return 0
  fi

  log "${svc}: buscando última imagem no ECR (${ecr_repo})…"
  local tag
  tag=$(ecr_latest_tag "${ecr_repo}" "[a-f0-9]{6,}(-amd64)?$")
  if [[ -z "${tag}" ]]; then
    log "❌ ${svc}: nenhuma tag válida encontrada no ECR (${ecr_repo})."
    return 1
  fi

  local image_uri
  image_uri=$(mk_image_uri "${ecr_repo}" "${tag}")
  log "${svc}: usando imagem ${image_uri}"

  # Deployment: preferencialmente deployment.yaml usando envsubst para IMAGE_URI
  if [[ -f "${k8s_dir}/deployment.yaml" ]]; then
    export IMAGE_URI="${image_uri}"
    envsubst < "${k8s_dir}/deployment.yaml" | kubectl apply -n app -f -
  else
    log "⚠️  ${svc}: deployment.yaml não encontrado em ${k8s_dir} (pulando deployment)."
  fi

  # Service e demais manifests (exceto deployment.yaml)
  if [[ -f "${k8s_dir}/service.yaml" ]]; then
    kubectl apply -n app -f "${k8s_dir}/service.yaml"
  elif [[ -f "${k8s_dir}/service.yml" ]]; then
    kubectl apply -n app -f "${k8s_dir}/service.yml"
  fi

  find "${k8s_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
    ! -name 'deployment.yaml' ! -name 'service.yaml' ! -name 'service.yml' -print0 | \
    xargs -0 -I{} kubectl -n app apply -f {} || true

  if kubectl -n app get deploy "${deploy_name}" >/dev/null 2>&1; then
    log "${svc}: aguardando rollout de ${deploy_name}…"
    kubectl -n app rollout status deploy "${deploy_name}" --timeout=180s || true
  fi
}

get_lb_endpoint() {
  # tenta resolver hostname ou IP do LoadBalancer
  local host ip ep
  host="$(kubectl -n "${LB_NAMESPACE}" get svc "${LB_SERVICE_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null | tr -d '[:space:]')"
  ip="$(kubectl -n "${LB_NAMESPACE}" get svc "${LB_SERVICE_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$host" ]]; then
    ep="$host"
  elif [[ -n "$ip" ]]; then
    ep="$ip"
  else
    ep=""
  fi
  printf "%s" "$ep"
}

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

case "${DB_STATUS}" in
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

# ====== 5) (Opcional) Aplicar manifests ======
if [[ "${APPLY_APP_MANIFESTS}" == "true" ]]; then
  # 5.1) Namespace(s) (sem -n)
  if [[ -d "${K8S_NS_DIR}" ]]; then
    log "Aplicando manifests de namespace em ${K8S_NS_DIR}…"
    kubectl apply -f "${K8S_NS_DIR}"
  else
    # fallback: garante pelo menos o namespace app
    kubectl get ns app >/dev/null 2>&1 || kubectl create namespace app
  fi

  # 5.2) Monolito (legacy) — DESABILITADO
  # Observação: o monolito não é mais usado. Este script NÃO faz deploy de imagem/manifests do monolito.
  # Se ainda existir algum recurso antigo no cluster, remova manualmente (ex.: `kubectl delete deploy lanchonete-app -n app`).
  log "Monolito desabilitado → pulando deploy do monolito (lanchonete-app)."

  # 5.3) (Opcional) Serviços (multi-repo)
  if [[ "${APPLY_ALL_SERVICES}" == "true" ]]; then
    log "APPLY_ALL_SERVICES=true → aplicando pedidos/producao/pagamento/orchestrator…"

    deploy_k8s_dir "pedidos" "${PEDIDOS_DIR}" "${ECR_PEDIDOS_REPO}" "${DEPLOY_PEDIDOS}"
    deploy_k8s_dir "producao" "${PRODUCAO_DIR}" "${ECR_PRODUCAO_REPO}" "${DEPLOY_PRODUCAO}"
    deploy_k8s_dir "pagamento" "${PAGAMENTO_DIR}" "${ECR_PAGAMENTO_REPO}" "${DEPLOY_PAGAMENTO}"
    deploy_k8s_dir "orchestrator" "${ORCHESTRATOR_DIR}" "${ECR_ORCHESTRATOR_REPO}" "${DEPLOY_ORCHESTRATOR}"

    log "✅ Serviços adicionais aplicados. Para checar: kubectl get deploy,svc,pods -n app"
  else
    log "APPLY_ALL_SERVICES=false → não aplicando serviços multi-repo."
  fi

  # 5.4) kube-system (com -n kube-system)
  if [[ -d "${K8S_SYS_DIR}" ]]; then
    log "Aplicando manifests do kube-system em ${K8S_SYS_DIR}…"
    # usar server-side para lidar com aws-auth e evitar conflitos de resourceVersion
    find "${K8S_SYS_DIR}" -type f -name '*.yaml' -print0 | xargs -0 -I{} kubectl -n kube-system apply --server-side --force-conflicts -f {}
  else
    log "Diretório kube-system não encontrado: ${K8S_SYS_DIR} (pulando)."
  fi

  # 5.5) Descobrir e mostrar o endpoint externo do LoadBalancer (se existir)
  log "Verificando endpoint do LoadBalancer (${LB_NAMESPACE}/${LB_SERVICE_NAME})…"
  if kubectl -n "${LB_NAMESPACE}" get svc "${LB_SERVICE_NAME}" >/dev/null 2>&1; then
    SECONDS=0
    LB_EP="$(get_lb_endpoint)"
    while [[ -z "${LB_EP}" && "${SECONDS}" -lt "${LB_WAIT_TIMEOUT}" ]]; do
      sleep 5
      LB_EP="$(get_lb_endpoint)"
    done

    if [[ -n "${LB_EP}" ]]; then
      echo
      echo "[resume] 🌐 Endpoint externo disponível:"
      echo "        - HTTP : http://${LB_EP}"
      echo "        - HTTPS: https://${LB_EP}"
      echo
    else
      log "Endpoint ainda não disponível após ${LB_WAIT_TIMEOUT}s. Você pode checar depois com:"
      echo "kubectl -n ${LB_NAMESPACE} get svc ${LB_SERVICE_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{\"\\n\"}{.status.loadBalancer.ingress[0].ip}{\"\\n\"}'"
    fi
  else
    log "Service ${LB_NAMESPACE}/${LB_SERVICE_NAME} não encontrado (ignorando descoberta de endpoint)."
  fi
else
  log "Aplicação dos manifests desabilitada (APPLY_APP_MANIFESTS=false)."
fi

# ====== 6) Verificações rápidas ======
log "Verificando nós do cluster…"
kubectl get nodes -o wide || true
log "Verificando namespaces básicos…"
kubectl get ns || true

# ====== 7) Retomar ambiente do serviço de autenticação (lanchonete-auth) ======
log "Chamando script de retomada no repositório de autenticação (lanchonete-auth)…"

AUTH_DIR="${REPO_ROOT}/lanchonete-auth"

if [[ -d "${AUTH_DIR}" && -f "${AUTH_DIR}/resume.sh" ]]; then
  log "Executando resume.sh do repositório lanchonete-auth…"
  (cd "${AUTH_DIR}" && ./resume.sh)
  log "✅ Script de retomada executado com sucesso."
else
  log "⚠️  Script de retomada não encontrado em ${AUTH_DIR}. Verifique se o repositório foi clonado corretamente."
fi

log "✅ Ambiente retomado (EKS ativo, kubeconfig atualizado, RDS em operação)."
log "Se houver Service LoadBalancer (${LB_NAMESPACE}/${LB_SERVICE_NAME}), o endpoint foi mostrado acima."