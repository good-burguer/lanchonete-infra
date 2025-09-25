#!/bin/bash
set -euo pipefail

AWS_REGION="us-east-1"
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
      --region "$AWS_REGION" || true
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
    -backend-config="encrypt=true"
}

# Destrói pelo Terraform (preferível)
destroy_via_tf() {
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

# Fallback direto na AWS caso o recurso exista fora do state
destroy_via_cli() {
  set +e
  STATUS=$(aws eks describe-cluster --name gb-dev-eks --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null)
  set -e
  if [[ "$STATUS" == "ACTIVE" || "$STATUS" == "CREATING" || "$STATUS" == "UPDATING" ]]; then
    log "EKS ainda existe na AWS (status: $STATUS). Removendo via CLI…"

    # Deleta nodegroups se houver
    NG_LIST=$(aws eks list-nodegroups --cluster-name gb-dev-eks --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null || true)
    for ng in $NG_LIST; do
      log "Apagando Node Group: $ng"
      aws eks delete-nodegroup --cluster-name gb-dev-eks --nodegroup-name "$ng" --region "$AWS_REGION" || true
      aws eks wait nodegroup_deleted --cluster-name gb-dev-eks --nodegroup-name "$ng" --region "$AWS_REGION" || true
    done

    log "Apagando Cluster: gb-dev-eks"
    aws eks delete-cluster --name gb-dev-eks --region "$AWS_REGION" || true
    aws eks wait cluster_deleted --name gb-dev-eks --region "$AWS_REGION" || true
  else
    log "Cluster EKS não encontrado ou já apagado."
  fi
}

stop_rds
init_tf

destroy_via_tf || true

destroy_via_cli || true

log "✅ Ambiente pausado (RDS parado, EKS destruído)."