#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-gb-dev-eks}"
REGION="${2:-us-east-1}"
POLICY_ARN="${3:-arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy}"
SCOPE_TYPE="${4:-cluster}"

echo "[1/6] Validando identidade AWS..."
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
echo "  - Caller ARN: ${CALLER_ARN}"

echo "[2/6] Atualizando kubeconfig..."
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null
echo "  - kubeconfig atualizado para ${CLUSTER_NAME} (${REGION})"

echo "[3/6] Garantindo EKS Access Entry para o principal..."
if aws eks describe-access-entry \
  --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --principal-arn "${CALLER_ARN}" >/dev/null 2>&1; then
  echo "  - Access Entry já existe."
else
  aws eks create-access-entry \
    --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${CALLER_ARN}" >/dev/null
  echo "  - Access Entry criado."
fi

echo "[4/6] Garantindo associação de policy (${POLICY_ARN})..."
if aws eks list-associated-access-policies \
  --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --principal-arn "${CALLER_ARN}" \
  --query "associatedAccessPolicies[].policyArn" \
  --output text | tr '\t' '\n' | grep -q "${POLICY_ARN}"; then
  echo "  - Policy já associada."
else
  aws eks associate-access-policy \
    --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${CALLER_ARN}" \
    --policy-arn "${POLICY_ARN}" \
    --access-scope "type=${SCOPE_TYPE}" >/dev/null
  echo "  - Policy associada."
fi

echo "[5/6] Testando acesso ao cluster..."
# dá um tempinho pro EKS propagar (geralmente é rápido, mas pode levar alguns segundos)
sleep 3

kubectl get nodes

echo "[6/6] OK ✅ Você está autenticado no EKS com ${CALLER_ARN}"