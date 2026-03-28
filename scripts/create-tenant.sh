#!/usr/bin/env bash
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-name> [cluster-name] [region]}"
CLUSTER="${2:-openclaw-cluster}"
REGION="${3:-us-west-2}"
NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
SECRET_ID="openclaw/${TENANT}/gateway-token"
ROLE_ARN="${OPENCLAW_TENANT_ROLE_ARN:?Set OPENCLAW_TENANT_ROLE_ARN env var}"
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/helm/charts/openclaw-platform"

echo "==> Creating tenant: ${TENANT}"

# 1. Generate random gateway token
TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# 2. Create secret in Secrets Manager
echo "  → Creating Secrets Manager secret: ${SECRET_ID}"
aws secretsmanager create-secret \
  --region "${REGION}" \
  --name "${SECRET_ID}" \
  --secret-string "${TOKEN}" \
  --tags "Key=tenant-namespace,Value=${NAMESPACE}" \
  --output text --query 'ARN'

# 3. Create Pod Identity Association
echo "  → Creating Pod Identity Association"
aws eks create-pod-identity-association \
  --region "${REGION}" \
  --cluster-name "${CLUSTER}" \
  --namespace "${NAMESPACE}" \
  --service-account "${RELEASE}" \
  --role-arn "${ROLE_ARN}" \
  --output text --query 'association.associationId'

# 4. Helm install
echo "  → Helm installing ${RELEASE}"
helm install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "tenant.name=${TENANT}" \
  --set "ingress.host=${TENANT}.openclaw.example.com" \
  --set "fullnameOverride=openclaw-${TENANT}" \
  --wait --timeout 120s

# 5. Wait for pod Ready
echo "  → Waiting for pod Ready"
kubectl wait pod \
  -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${RELEASE}" \
  --for=condition=Ready \
  --timeout=120s

# 6. Summary
POD=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}')
echo ""
echo "=== Tenant Created ==="
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Pod:        ${POD}"
echo "  Secret:     ${SECRET_ID}"
echo "  Ingress:    ${TENANT}.openclaw.example.com"
echo "======================"
