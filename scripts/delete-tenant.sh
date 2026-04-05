#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

FORCE=false
TENANT=""

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

echo "==> About to delete tenant: ${TENANT}"
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Secret:     ${SECRET_ID}"
echo ""

# Confirmation
if [[ "$FORCE" != true ]]; then
  read -rp "Are you sure? Type tenant name to confirm: " CONFIRM
  [[ "$CONFIRM" != "$TENANT" ]] && { echo "Aborted."; exit 1; }
fi

echo ""
echo "==> Deleting tenant: ${TENANT}"

# 1. Remove element from ApplicationSet (must be first — otherwise ApplicationSet recreates everything)
echo "  → Removing from ApplicationSet"
APPSET=$(kubectl get applicationset openclaw-tenants -n argocd -o json 2>/dev/null)
if [[ -z "${APPSET}" ]]; then
  echo "    ⚠️ ApplicationSet not found — skipping element removal"
else
  UPDATED=$(echo "$APPSET" | TENANT="$TENANT" python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    elements = d['spec']['generators'][0]['list']['elements']
    before = len(elements)
    d['spec']['generators'][0]['list']['elements'] = [e for e in elements if e.get('name') != os.environ['TENANT']]
    after = len(d['spec']['generators'][0]['list']['elements'])
    if before == after:
        print(f'WARNING: tenant {os.environ[\"TENANT\"]} not in ApplicationSet', file=sys.stderr)
    json.dump(d, sys.stdout)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")
  if [[ -z "${UPDATED}" ]]; then
    echo "    ❌ Failed to update ApplicationSet. Aborting to prevent resurrection."
    exit 1
  fi
  echo "$UPDATED" | kubectl apply -f -
  echo "    ✅ Element removed from ApplicationSet"
fi

# 2. ArgoCD Application (Delete=false means removing element doesn't auto-delete)
echo "  → Deleting ArgoCD Application: ${TENANT}"
kubectl delete application "${TENANT}" -n argocd --ignore-not-found 2>/dev/null || echo "    (ArgoCD app not found, skipping)"

# 3. Delete namespace (PVCs deleted with it → CSI deletes EFS access point)
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
echo "  ArgoCD:     ${TENANT} (removed from ApplicationSet)"
echo "======================"
