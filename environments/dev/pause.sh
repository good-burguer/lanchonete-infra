#!/bin/bash
set -euo pipefail

# Desabilita pager do AWS CLI para evitar "(END)"
export AWS_PAGER=""
export AWS_REGION="${AWS_REGION:-us-east-1}"

EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-gb-dev-eks}"
K8S_NAMESPACE="${K8S_NAMESPACE:-app}"

# (legado) nome específico do LB. Mantido por compatibilidade, mas o script agora
# remove TODOS os Services do tipo LoadBalancer no namespace.
LB_SERVICE_NAME="${LB_SERVICE_NAME:-lanchonete-orchestrator-lb}"

# Timeout (segundos) para aguardar o provedor de nuvem remover o Load Balancer após deletar o Service
LB_DELETE_TIMEOUT_SECONDS="${LB_DELETE_TIMEOUT_SECONDS:-900}"

TF_BUCKET="${TF_BUCKET:-good-burger-tf-state}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-good-burger-tf-lock}"
TF_KEY="${TF_KEY:-infra/terraform.tfstate}"

log() { echo -e "\n==> $*"; }

delete_load_balancer() {
  log "Removendo Services do tipo LoadBalancer no namespace ${K8S_NAMESPACE}…"

  # Lista todos os Services LoadBalancer (pode existir mais de 1, ex: monolito legado)
  mapfile -t LB_SVCS < <(kubectl get svc -n "${K8S_NAMESPACE}" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [[ ${#LB_SVCS[@]} -eq 0 ]]; then
    log "Nenhum Service do tipo LoadBalancer encontrado no namespace ${K8S_NAMESPACE}."
    return 0
  fi

  # Captura os DNS atuais (EXTERNAL-IP) antes de deletar, para conseguir aguardar a remoção na AWS
  declare -a LB_DNS
  for svc in "${LB_SVCS[@]}"; do
    dns=$(kubectl get svc "$svc" -n "${K8S_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "${dns:-}" && "$dns" != "<none>" ]]; then
      LB_DNS+=("$dns")
    fi
  done

  for svc in "${LB_SVCS[@]}"; do
    log "- Deletando Service LoadBalancer: ${svc}"
    set +e
    kubectl delete svc "${svc}" -n "${K8S_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1
    set -e
  done

  # Aguarda os services sumirem do cluster
  local start_ts now elapsed
  start_ts=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start_ts))
    if (( elapsed > LB_DELETE_TIMEOUT_SECONDS )); then
      log "⚠️  Timeout aguardando Services LoadBalancer serem removidos do cluster. Continuando mesmo assim."
      break
    fi

    remaining=$(kubectl get svc -n "${K8S_NAMESPACE}" \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ' || echo 0)

    if [[ "${remaining}" == "0" ]]; then
      log "Services LoadBalancer removidos do cluster."
      break
    fi
    sleep 5
  done

  # Agora, a remoção do Load Balancer na AWS pode ser ASSÍNCRONA.
  # Vamos aguardar e, se ainda existir após o timeout, tentar um delete best-effort via AWS CLI.
  if [[ ${#LB_DNS[@]} -eq 0 ]]; then
    log "Nenhum DNS de LB capturado (talvez ainda não tinha EXTERNAL-IP). Pulando verificação na AWS."
    return 0
  fi

  log "Aguardando remoção do Load Balancer na AWS (até ${LB_DELETE_TIMEOUT_SECONDS}s)…"

  start_ts=$(date +%s)
  for dns in "${LB_DNS[@]}"; do
    while true; do
      now=$(date +%s)
      elapsed=$((now - start_ts))
      if (( elapsed > LB_DELETE_TIMEOUT_SECONDS )); then
        log "⚠️  Timeout aguardando o LB (${dns}) desaparecer na AWS. Tentando delete best-effort…"

        # 1) Classic ELB
        set +e
        elb_name=$(aws elb describe-load-balancers --region "$AWS_REGION" \
          --query "LoadBalancerDescriptions[?DNSName=='${dns}'].LoadBalancerName | [0]" \
          --output text 2>/dev/null)
        set -e
        if [[ -n "${elb_name:-}" && "${elb_name}" != "None" && "${elb_name}" != "null" ]]; then
          log "- Removendo Classic ELB via AWS CLI: ${elb_name}"
          aws elb delete-load-balancer --load-balancer-name "${elb_name}" --region "$AWS_REGION" >/dev/null 2>&1 || true
        fi

        # 2) ALB/NLB (ELBv2)
        set +e
        elbv2_arn=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
          --query "LoadBalancers[?DNSName=='${dns}'].LoadBalancerArn | [0]" \
          --output text 2>/dev/null)
        set -e
        if [[ -n "${elbv2_arn:-}" && "${elbv2_arn}" != "None" && "${elbv2_arn}" != "null" ]]; then
          log "- Removendo ELBv2 (ALB/NLB) via AWS CLI: ${elbv2_arn}"
          aws elbv2 delete-load-balancer --load-balancer-arn "${elbv2_arn}" --region "$AWS_REGION" >/dev/null 2>&1 || true
        fi

        break
      fi

      # Check classic ELB existe?
      set +e
      elb_exists=$(aws elb describe-load-balancers --region "$AWS_REGION" \
        --query "length(LoadBalancerDescriptions[?DNSName=='${dns}'])" --output text 2>/dev/null)
      # Check elbv2 existe?
      elbv2_exists=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "length(LoadBalancers[?DNSName=='${dns}'])" --output text 2>/dev/null)
      set -e

      elb_exists=${elb_exists:-0}
      elbv2_exists=${elbv2_exists:-0}

      if [[ "$elb_exists" == "0" && "$elbv2_exists" == "0" ]]; then
        log "✅ LB removido na AWS: ${dns}"
        break
      fi

      sleep 10
    done
  done
}

stop_rds() {
  log "Parando RDS (gb-dev-postgres) se estiver AVAILABLE…"
  set +e
  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier gb-dev-postgres \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  set -e
  if [[ "$STATUS" == "available" ]]; then
    aws rds stop-db-instance \
      --db-instance-identifier gb-dev-postgres \
      --region "$AWS_REGION" >/dev/null || true
  else
    log "RDS não está em estado 'available' (status atual: ${STATUS:-desconhecido}). Ignorando stop."
  fi
}

init_tf() {
  log "Inicializando Terraform (backend S3 + DynamoDB)…"
  terraform init -input=false -reconfigure \
    -backend-config="bucket=${TF_BUCKET}" \
    -backend-config="key=${TF_KEY}" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
    -backend-config="encrypt=true" >/dev/null
  log "Terraform init OK."
}

destroy_via_tf() {
  # Best-effort cleanup via Terraform state (does not fail the script)
  # Destruição preferencial usando TF, mas sem falhar o script se o state não tiver os recursos
  log "Destruindo EKS Node Group (se estiver no state)…"
  if terraform state list 2>/dev/null | grep -q '^aws_eks_node_group\.default$'; then
    terraform destroy -lock-timeout=5m -auto-approve \
      -target=aws_eks_node_group.default \
      -var="aws_region=$AWS_REGION" \
      -var="tf_state_bucket=$TF_BUCKET" \
      -var="tf_lock_table=$TF_LOCK_TABLE" || true
  else
    log "Node Group não está no state do Terraform."
  fi

  log "Destruindo EKS Cluster (se estiver no state)…"
  if terraform state list 2>/dev/null | grep -q '^aws_eks_cluster\.this$'; then
    terraform destroy -lock-timeout=5m -auto-approve \
      -target=aws_eks_cluster.this \
      -var="aws_region=$AWS_REGION" \
      -var="tf_state_bucket=$TF_BUCKET" \
      -var="tf_lock_table=$TF_LOCK_TABLE" || true
  else
    log "Cluster não está no state do Terraform."
  fi
}

# Espera com timeout simples (segundos)
wait_with_spinner() {
  local seconds=$1 msg=$2
  local i=0; local spin='|/-\'
  printf "%s " "$msg"
  while (( i < seconds )); do
    printf "\r%s %s" "$msg" "${spin:i%${#spin}:1}"
    sleep 1
    ((i++))
  done
  printf "\r%s ✔\n" "$msg"
}

destroy_via_cli() {
  # Checa se cluster existe
  set +e
  STATUS=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null)
  set -e
  if [[ "$STATUS" != "ACTIVE" && "$STATUS" != "CREATING" && "$STATUS" != "UPDATING" ]]; then
    log "Cluster EKS não encontrado ou já apagado."
    return 0
  fi

  log "EKS ainda existe na AWS (status: $STATUS). Removendo via CLI…"

  # Deleta todos os nodegroups e aguarda
  NG_LIST=$(aws eks list-nodegroups --cluster-name "${EKS_CLUSTER_NAME}" --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null || true)
  if [[ -n "${NG_LIST:-}" ]]; then
    for ng in $NG_LIST; do
      log "Apagando Node Group: $ng"
      aws eks delete-nodegroup --cluster-name "${EKS_CLUSTER_NAME}" --nodegroup-name "$ng" --region "$AWS_REGION" >/dev/null || true
      log "Aguardando nodegroup-deleted ($ng)…"
      # Nome correto do waiter: nodegroup-deleted
      aws eks wait nodegroup-deleted --cluster-name "${EKS_CLUSTER_NAME}" --nodegroup-name "$ng" --region "$AWS_REGION" || true
    done
  else
    log "Nenhum Node Group para apagar."
  fi

  # Double-check: aguarda até listar vazio (sem falhar)
  for _ in {1..30}; do
    REMAINING=$(aws eks list-nodegroups --cluster-name "${EKS_CLUSTER_NAME}" --region "$AWS_REGION" --query 'length(nodegroups)' --output text 2>/dev/null || echo 0)
    if [[ "${REMAINING}" == "0" ]]; then break; fi
    sleep 5
  done

  log "Apagando Cluster: ${EKS_CLUSTER_NAME}"
  aws eks delete-cluster --name "${EKS_CLUSTER_NAME}" --region "$AWS_REGION" >/dev/null || true
  log "Aguardando cluster-deleted…"
  # Nome correto do waiter: cluster-deleted
  aws eks wait cluster-deleted --name "${EKS_CLUSTER_NAME}" --region "$AWS_REGION" || true
}

delete_load_balancer
stop_rds
init_tf
destroy_via_tf || true
destroy_via_cli || true

log "Chamando script de parada no repositório de autenticação (lanchonete-auth)…"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="${SCRIPT_DIR}/../../../lanchonete-auth"

if [[ -d "$AUTH_DIR" && -f "$AUTH_DIR/pause.sh" ]]; then
  log "Executando pause.sh do repositório lanchonete-auth…"
  (cd "$AUTH_DIR" && ./pause.sh)
  log "✅ Script de parada executado com sucesso."
else
  log "⚠️  Script de parada não encontrado em $AUTH_DIR. Verifique se o repositório foi clonado corretamente."
fi

log "✅ Ambiente pausado: LoadBalancer removido, RDS parado e EKS destruído."