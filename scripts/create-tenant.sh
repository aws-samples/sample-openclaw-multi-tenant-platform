#!/usr/bin/env bash
# Create a tenant by adding it to the ApplicationSet.
# ArgoCD automatically creates the Application → Helm syncs all resources.
# Usage: ./scripts/create-tenant.sh <name> [--email <email>]
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

usage() {
  echo "Usage: $0 <tenant-name> [--email <email>]"
  exit 1
}

TENANT="" EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) TENANT="$1"; shift ;;
  esac
done

[[ -z "$TENANT" ]] && usage
[[ -z "$EMAIL" ]] && EMAIL="${TENANT}@example.com"

echo "Creating tenant: ${TENANT}"
echo "  Email: ${EMAIL}"

NAMESPACE="openclaw-${TENANT}"
SECRET_NAME="openclaw/${TENANT}/gateway-token"
TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

# Read current ApplicationSet, append element, write back
APPSET=$(kubectl get applicationset openclaw-tenants -n argocd -o json)

# Check if tenant already exists
if echo "$APPSET" | TENANT="$TENANT" python3 -c "
import json, sys, os
d = json.load(sys.stdin)
elements = d.get('spec',{}).get('generators',[{}])[0].get('list',{}).get('elements',[])
sys.exit(0 if any(e.get('name')==os.environ['TENANT'] for e in elements) else 1)
" 2>/dev/null; then
  echo "Tenant ${TENANT} already exists in ApplicationSet"
  exit 0
fi

# Append new element
UPDATED=$(echo "$APPSET" | TENANT="$TENANT" EMAIL="$EMAIL" python3 -c "
import json, sys, os
d = json.load(sys.stdin)
try:
    elements = d['spec']['generators'][0]['list']['elements']
    elements.append({'name': os.environ['TENANT'], 'email': os.environ['EMAIL']})
    json.dump(d, sys.stdout)
except (KeyError, IndexError, TypeError) as e:
    print(f'Error: ApplicationSet structure is invalid: {e}', file=sys.stderr)
    sys.exit(1)
")

echo "$UPDATED" | kubectl apply -f - >/dev/null

# Create Pod Identity Association
echo "  → Creating Pod Identity Association"
aws eks create-pod-identity-association \
  --cluster-name "${CLUSTER}" --namespace "${NAMESPACE}" \
  --service-account "${TENANT}" \
  --role-arn "$(aws cloudformation describe-stacks --stack-name OpenClawEksStack --region "${REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`TenantRoleArn`].OutputValue' --output text)" \
  --region "${REGION}" 2>/dev/null || echo "    (already exists)"

# Create gateway token in Secrets Manager
echo "  → Creating gateway token in Secrets Manager"
aws secretsmanager create-secret \
  --name "${SECRET_NAME}" --secret-string "${TOKEN}" \
  --tags Key=tenant,Value="${TENANT}" Key=tenant-namespace,Value="${NAMESPACE}" \
  --region "${REGION}" 2>/dev/null || \
aws secretsmanager update-secret \
  --secret-id "${SECRET_NAME}" --secret-string "${TOKEN}" \
  --region "${REGION}" 2>/dev/null || echo "    (already exists)"

# Wait for namespace to be created by ArgoCD
echo "  → Waiting for namespace ${NAMESPACE}..."
for i in $(seq 1 30); do
  kubectl get namespace "${NAMESPACE}" &>/dev/null && break
  sleep 5
done

# Create K8s Secret with gateway token
echo "  → Creating K8s gateway-token Secret"
kubectl create secret generic "${TENANT}-gateway-token" \
  --namespace "${NAMESPACE}" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo ""
echo "Tenant added to ApplicationSet. ArgoCD will create the workspace:"
echo "  kubectl get application tenant-${TENANT} -n argocd -w"
