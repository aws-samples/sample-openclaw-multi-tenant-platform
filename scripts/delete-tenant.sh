#!/usr/bin/env bash
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-name> [cluster-name] [region]}"
CLUSTER="${2:-openclaw-cluster}"
REGION="${3:-us-west-2}"
NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
SECRET_ID="openclaw/${TENANT}/gateway-token"

echo "==> Deleting tenant: ${TENANT}"

# 1. Helm uninstall
echo "  → Helm uninstalling ${RELEASE}"
helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" 2>/dev/null || echo "    (release not found, skipping)"

# 2. Delete namespace
echo "  → Deleting namespace ${NAMESPACE}"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s

# 3. Delete Pod Identity Association
echo "  → Deleting Pod Identity Association"
ASSOC_ID=$(aws eks list-pod-identity-associations \
  --region "${REGION}" \
  --cluster-name "${CLUSTER}" \
  --namespace "${NAMESPACE}" \
  --service-account "${RELEASE}" \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || true)

if [[ -n "${ASSOC_ID}" && "${ASSOC_ID}" != "None" ]]; then
  aws eks delete-pod-identity-association \
    --region "${REGION}" \
    --cluster-name "${CLUSTER}" \
    --association-id "${ASSOC_ID}"
  echo "    Deleted association: ${ASSOC_ID}"
else
  echo "    (no association found, skipping)"
fi

# 4. Delete Secrets Manager secret
echo "  → Deleting secret: ${SECRET_ID}"
aws secretsmanager delete-secret \
  --region "${REGION}" \
  --secret-id "${SECRET_ID}" \
  --force-delete-without-recovery 2>/dev/null || echo "    (secret not found, skipping)"

echo ""
echo "=== Tenant Deleted ==="
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Secret:     ${SECRET_ID}"
echo "======================"
