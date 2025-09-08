#!/bin/bash
set -euo pipefail

# Desabilita pager do AWS CLI para evitar "(END)"
export AWS_PAGER=""
export AWS_REGION="us-east-1"

TF_BUCKET="good-burger-tf-state"
TF_LOCK_TABLE="good-burger-tf-lock"

log() { echo -e "\n==> $*"; }

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
  terraform init -input=false \
    -backend-config="bucket=$TF_BUCKET" \
    -backend-config="key=infra/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TF_LOCK_TABLE" \
    -backend-config="encrypt=true" >/dev/null
  log "Terraform init OK."
}

destroy_via_tf() {
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
  STATUS=$(aws eks describe-cluster --name gb-dev-eks --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null)
  set -e
  if [[ "$STATUS" != "ACTIVE" && "$STATUS" != "CREATING" && "$STATUS" != "UPDATING" ]]; then
    log "Cluster EKS não encontrado ou já apagado."
    return 0
  fi

  log "EKS ainda existe na AWS (status: $STATUS). Removendo via CLI…"

  # Deleta todos os nodegroups e aguarda
  NG_LIST=$(aws eks list-nodegroups --cluster-name gb-dev-eks --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null || true)
  if [[ -n "${NG_LIST:-}" ]]; then
    for ng in $NG_LIST; do
      log "Apagando Node Group: $ng"
      aws eks delete-nodegroup --cluster-name gb-dev-eks --nodegroup-name "$ng" --region "$AWS_REGION" >/dev/null || true
      log "Aguardando nodegroup-deleted ($ng)…"
      # Nome correto do waiter: nodegroup-deleted
      aws eks wait nodegroup-deleted --cluster-name gb-dev-eks --nodegroup-name "$ng" --region "$AWS_REGION" || true
    done
  else
    log "Nenhum Node Group para apagar."
  fi

  # Double-check: aguarda até listar vazio (sem falhar)
  for _ in {1..30}; do
    REMAINING=$(aws eks list-nodegroups --cluster-name gb-dev-eks --region "$AWS_REGION" --query 'length(nodegroups)' --output text 2>/dev/null || echo 0)
    if [[ "${REMAINING}" == "0" ]]; then break; fi
    sleep 5
  done

  log "Apagando Cluster: gb-dev-eks"
  aws eks delete-cluster --name gb-dev-eks --region "$AWS_REGION" >/dev/null || true
  log "Aguardando cluster-deleted…"
  # Nome correto do waiter: cluster-deleted
  aws eks wait cluster-deleted --name gb-dev-eks --region "$AWS_REGION" || true
}

stop_rds
init_tf
destroy_via_tf || true
destroy_via_cli || true

log "✅ Ambiente pausado (RDS parado, EKS destruído)."