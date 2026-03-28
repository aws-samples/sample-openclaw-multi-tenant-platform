#!/usr/bin/env bash
set -euo pipefail

FORCE=false
TENANT="" CLUSTER="openclaw-cluster" REGION="us-west-2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 <tenant-name> [--force] [--cluster <name>] [--region <region>]"; exit 0 ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) TENANT="$1"; shift ;;
  esac
done

[[ -z "$TENANT" ]] && { echo "Usage: $0 <tenant-name> [--force] [--cluster <name>] [--region <region>]"; exit 1; }

NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
SECRET_ID="openclaw/${TENANT}/gateway-token"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TENANT_VALUES="${REPO_DIR}/helm/tenants/values-${TENANT}.yaml"

echo "==> About to delete tenant: ${TENANT}"
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Secret:     ${SECRET_ID}"
echo "  Values:     ${TENANT_VALUES}"
echo ""

# Confirmation
if [[ "$FORCE" != true ]]; then
  read -rp "Are you sure? Type tenant name to confirm: " CONFIRM
  [[ "$CONFIRM" != "$TENANT" ]] && { echo "Aborted."; exit 1; }
fi

echo ""
echo "==> Deleting tenant: ${TENANT}"

# 1. ArgoCD Application (if exists)
ARGO_APP="values-${TENANT}"
echo "  → Deleting ArgoCD Application: ${ARGO_APP}"
kubectl delete application "${ARGO_APP}" -n argocd --ignore-not-found 2>/dev/null || echo "    (ArgoCD app not found, skipping)"

# 2. Helm uninstall
echo "  → Helm uninstalling ${RELEASE}"
helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" 2>/dev/null || echo "    (release not found, skipping)"

# 3. Delete namespace (PVCs deleted with it)
echo "  → Deleting namespace ${NAMESPACE} (includes PVCs)"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s

# 4. Pod Identity Association
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

# 5. Secrets Manager secret
echo "  → Deleting secret: ${SECRET_ID}"
aws secretsmanager delete-secret \
  --region "${REGION}" \
  --secret-id "${SECRET_ID}" \
  --force-delete-without-recovery 2>/dev/null || echo "    (secret not found, skipping)"

# 6. Tenant values file
echo "  → Deleting values file: ${TENANT_VALUES}"
rm -f "${TENANT_VALUES}"

# 7. Verify
echo ""
echo "==> Verifying deletion..."
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "  ✗ Namespace ${NAMESPACE} still exists!"
  exit 1
else
  echo "  ✓ Namespace ${NAMESPACE} not found (deleted)"
fi

echo ""
echo "=== Tenant Deleted ==="
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Secret:     ${SECRET_ID}"
echo "  ArgoCD:     ${ARGO_APP}"
echo "  Values:     ${TENANT_VALUES}"
echo "======================"
