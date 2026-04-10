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

# Resolve TenantRoleArn from stack outputs
TENANT_ROLE_ARN=$(get_output TenantRoleArn)
if [[ -z "$TENANT_ROLE_ARN" ]]; then
  log_error "Could not resolve TenantRoleArn from stack outputs."
  log_error "Ensure CDK stack is deployed: aws cloudformation describe-stacks --stack-name ${STACK}"
  exit 1
fi

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
if ! aws eks create-pod-identity-association \
  --cluster-name "${CLUSTER}" --namespace "${NAMESPACE}" \
  --service-account "${TENANT}" \
  --role-arn "${TENANT_ROLE_ARN}" \
  --region "${REGION}" 2>/dev/null; then
  # Check if it already exists (idempotent)
  EXISTING=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER}" \
    --namespace "${NAMESPACE}" --service-account "${TENANT}" \
    --region "${REGION}" --query 'associations[0].associationId' --output text 2>/dev/null)
  if [[ -z "$EXISTING" || "$EXISTING" = "None" ]]; then
    log_error "Failed to create Pod Identity Association. Check IAM permissions."
    exit 1
  fi
  echo "    (already exists)"
fi

# Create gateway token in Secrets Manager
echo "  → Creating gateway token in Secrets Manager"
if ! aws secretsmanager create-secret \
  --name "${SECRET_NAME}" --secret-string "${TOKEN}" \
  --tags Key=tenant,Value="${TENANT}" Key=tenant-namespace,Value="${NAMESPACE}" \
  --region "${REGION}" 2>/dev/null; then
  # Secret may already exist — try update
  if ! aws secretsmanager update-secret \
    --secret-id "${SECRET_NAME}" --secret-string "${TOKEN}" \
    --region "${REGION}" 2>/dev/null; then
    # May be in deleted state — try restore
    if ! aws secretsmanager restore-secret --secret-id "${SECRET_NAME}" --region "${REGION}" 2>/dev/null; then
      log_error "Failed to create/update Secrets Manager secret: ${SECRET_NAME}"
      exit 1
    fi
    if ! aws secretsmanager update-secret --secret-id "${SECRET_NAME}" --secret-string "${TOKEN}" --region "${REGION}" 2>/dev/null; then
      log_error "Secret restored but failed to update with new token: ${SECRET_NAME}"
      exit 1
    fi
  fi
  echo "    (updated existing)"
fi

# Wait for namespace to be created by ArgoCD
echo "  → Waiting for namespace ${NAMESPACE}..."
NS_READY=false
for i in $(seq 1 30); do
  if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    NS_READY=true
    break
  fi
  sleep 5
done
if [[ "$NS_READY" != "true" ]]; then
  log_error "Namespace ${NAMESPACE} was not created within 150s."
  log_error "Check ArgoCD: kubectl get application tenant-${TENANT} -n argocd -o yaml"
  exit 1
fi

# Create K8s Secret with gateway token
echo "  → Creating K8s gateway-token Secret"
kubectl create secret generic "${TENANT}-gateway-token" \
  --namespace "${NAMESPACE}" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Verify: wait for ArgoCD sync + trigger scale-up + confirm endpoint
echo "  → Verifying deployment..."
ALB=$(kubectl get gateway openclaw-gateway -n openclaw-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
DOMAIN=$(node -e "try{console.log(require('cdk/cdk.json').context.zoneName||'')}catch(e){console.log('')}" 2>/dev/null)

# If no custom domain, use CloudFront distribution domain
if [[ -z "$DOMAIN" || "$DOMAIN" == "example.com" ]]; then
  DOMAIN=$(aws cloudformation describe-stacks --stack-name OpenClawEksStack --region "${AWS_REGION:-us-east-1}" \
    --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" --output text 2>/dev/null || echo "")
fi

if [[ -z "$ALB" || -z "$DOMAIN" ]]; then
  echo ""
  echo "=== ⚠️ Tenant Created (skipping verification) ==="
  echo "  Name:      ${TENANT}"
  echo "  Namespace: ${NAMESPACE}"
  echo "  Gateway ALB or domain not available yet. Verify manually:"
  echo "    kubectl get gateway openclaw-gateway -n openclaw-system"
  echo "======================================================"
  exit 0
fi

VERIFIED=false
CODE=""
# Resolve ALB IP for --resolve (avoids -k flag, proper cert validation against DOMAIN)
ALB_IP=$(dig +short "${ALB}" 2>/dev/null | head -1)
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${DOMAIN}:443:${ALB_IP}" \
    "https://${DOMAIN}/t/${TENANT}/" 2>/dev/null || echo "000")
  if [[ "$CODE" = "200" ]]; then
    VERIFIED=true
    break
  fi
  sleep 10
done

echo ""
if [[ "$VERIFIED" = "true" ]]; then
  echo "=== ✅ Tenant Ready ==="
  echo "  Name:      ${TENANT}"
  echo "  Namespace: ${NAMESPACE}"
  echo "  URL:       https://${DOMAIN}/t/${TENANT}/"
  echo "========================"
else
  echo "=== ⚠️ Tenant Created (verification timeout) ==="
  echo "  Name:      ${TENANT}"
  echo "  Namespace: ${NAMESPACE}"
  echo "  Resources created but endpoint not yet responding (HTTP ${CODE})."
  echo "  This is normal if ALB is still provisioning (~2-3 min)."
  echo "  Check: curl --resolve '${DOMAIN}:443:${ALB_IP}' https://${DOMAIN}/t/${TENANT}/"
  echo "======================================================"
fi
