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

echo
echo "[resume] Buscando última imagem disponível no ECR..."

APP_IMAGE_URI=$(aws ecr list-images \
  --repository-name lanchonete-app \
  --region us-east-1 \
  --query 'imageIds[].imageTag' \
  --output text | tr '\t' '\n' | grep -v None | grep -E '[a-f0-9]{6,}-amd64$' | tail -n1)

if [ -z "$APP_IMAGE_URI" ]; then
  echo "[resume] ❌ Nenhuma imagem válida encontrada no ECR. Abortando..."
  exit 1
fi

APP_IMAGE_URI="822619186337.dkr.ecr.us-east-1.amazonaws.com/lanchonete-app:$APP_IMAGE_URI"
echo
echo "[resume] Imagem da aplicação (APP_IMAGE_URI): $APP_IMAGE_URI"

: "${LB_NAMESPACE:=app}"                 # namespace onde está o Service do LB
: "${LB_SERVICE_NAME:=lanchonete-svc}"   # nome do Service (tipo LoadBalancer)
: "${LB_WAIT_TIMEOUT:=300}"              # tempo máximo (segundos) para aparecer o endpoint

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

    [ -z "${APP_IMAGE_URI}" ] && {
      echo "[resume] Buscando imagem mais recente no ECR para o repositório lanchonete-app..."
      IMAGE_TAG=$(aws ecr describe-images \
        --repository-name lanchonete-app \
        --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
        --output text)

      if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "None" ]]; then
        echo "[resume] ❌ Nenhuma imagem com tag encontrada no repositório lanchonete-app. Abortando."
        exit 1
      fi

      APP_IMAGE_URI="822619186337.dkr.ecr.us-east-1.amazonaws.com/lanchonete-app:${IMAGE_TAG}"
      echo "[resume] Usando imagem mais recente disponível: $APP_IMAGE_URI"
    }
    export APP_IMAGE_URI

    log "Aplicando manifests da aplicação em ${K8S_APP_DIR} (namespace app)…"
    # 5.2.0) Validar imagem no ECR (auto-fallback para a última válida)
    # Se APP_IMAGE_URI não existir no ECR, pega a última imagem válida e usa no deploy
    repo_path="${APP_IMAGE_URI%:*}"            # ex: 8226....amazonaws.com/lanchonete-app
    repo_name="${repo_path##*/}"               # ex: lanchonete-app
    tag="${APP_IMAGE_URI##*:}"                 # ex: abc123-amd64

    if ! aws ecr describe-images \
          --repository-name "${repo_name}" \
          --image-ids imageTag="${tag}" \
          --region "${AWS_REGION}" >/dev/null 2>&1; then
      echo "[resume] Imagem não encontrada no ECR: ${APP_IMAGE_URI}. Buscando última tag válida…"

      # Buscar a imagem mais recente com tag válida
      LATEST_TAG=$(aws ecr describe-images \
        --repository-name "${repo_name}" \
        --region "${AWS_REGION}" \
        --query 'reverse(sort_by(imageDetails[?imageTags], & imagePushedAt))[0].imageTags[0]' \
        --output text 2>/dev/null | tr -d '\n\r')

      if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "None" ]]; then
        echo "[resume] ❌ Nenhuma imagem com tag válida encontrada no repositório ${repo_name}. Abortando."
        exit 1
      fi

      APP_IMAGE_URI="${repo_path}:${LATEST_TAG}"
      echo "[resume] Usando fallback para a imagem mais recente do ECR: ${APP_IMAGE_URI}"
    fi

    # 5.2.1) Renderiza e aplica o Deployment com a imagem parametrizada
    if [[ -f "${K8S_APP_DIR}/deployment.yaml" ]]; then
      log "Renderizando deployment com APP_IMAGE_URI=${APP_IMAGE_URI}…"
      cp "${K8S_APP_DIR}/deployment.yaml" ./deployment.temp.yaml
      APP_IMAGE_URI="${APP_IMAGE_URI}" yq e '.spec.template.spec.containers[0].image = strenv(APP_IMAGE_URI)' -i ./deployment.temp.yaml
      kubectl -n app apply -f ./deployment.temp.yaml
      rm -f ./deployment.temp.yaml
    else
      log "Arquivo deployment.yaml não encontrado em ${K8S_APP_DIR}."
    fi

    # 5.2.2) Aplica os demais manifests da aplicação (exceto o deployment, que já foi)
    find "${K8S_APP_DIR}" -type f -name '*.yaml' ! -name 'deployment.yaml' -print0 | xargs -0 -I{} kubectl -n app apply -f {}

    # 5.2.3) Aguarda rollout do deployment (se existir)
    if kubectl -n app get deploy lanchonete-app >/dev/null 2>&1; then
      kubectl -n app rollout status deploy/lanchonete-app --timeout=60s || \
        log "Rollout não completou em 60s. Verifique com 'kubectl -n app get pods' e 'kubectl -n app describe pod ...'."
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

  # 5.4) Descobrir e mostrar o endpoint externo do LoadBalancer (se existir)
  log "Verificando endpoint do LoadBalancer (${LB_NAMESPACE}/${LB_SERVICE_NAME})…"
  if kubectl -n "${LB_NAMESPACE}" get svc "${LB_SERVICE_NAME}" >/dev/null 2>&1; then
    # aguarda até LB expor hostname/IP ou até estourar timeout
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="${SCRIPT_DIR}/../../../lanchonete-auth"

if [[ -d "$AUTH_DIR" && -f "$AUTH_DIR/resume.sh" ]]; then
  log "Executando resume.sh do repositório lanchonete-auth…"
  (cd "$AUTH_DIR" && ./resume.sh)
  log "✅ Script de retomada executado com sucesso."
else
  log "⚠️  Script de retomada não encontrado em $AUTH_DIR. Verifique se o repositório foi clonado corretamente."
fi

log "✅ Ambiente retomado (EKS ativo, kubeconfig atualizado, RDS em operação)."
log "Se houver Service LoadBalancer (${LB_NAMESPACE}/${LB_SERVICE_NAME}), o endpoint foi mostrado acima."