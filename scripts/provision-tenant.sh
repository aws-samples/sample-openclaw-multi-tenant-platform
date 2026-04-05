#!/usr/bin/env bash
# provision-tenant.sh — Manually provision a tenant when PostConfirmation Lambda fails.
#
# Usage:
#   ./scripts/provision-tenant.sh <tenant-id> <email> [cognito-username]
#
# Prerequisites:
#   - kubectl configured for the EKS cluster
#   - AWS CLI with permissions for Secrets Manager, Cognito, EKS
#   - CDK stack outputs available (or set env vars manually)
#
# What this does (mirrors PostConfirmation Lambda steps 3-7):
#   1. Create Pod Identity Association
#   2. Create gateway token in Secrets Manager
#   3. Update Cognito user attributes
#   4. Add tenant to ApplicationSet (ArgoCD creates namespace + syncs Helm chart)
#   5. Create K8s Secret with gateway token
#   6. Wait for tenant to reach Healthy state

set -euo pipefail

TENANT="${1:?Usage: provision-tenant.sh <tenant-id> <email> [cognito-username]}"
EMAIL="${2:?Usage: provision-tenant.sh <tenant-id> <email> [cognito-username]}"
USERNAME="${3:-$EMAIL}"
NS="openclaw-${TENANT}"

# --- Resolve cluster config from CDK outputs ---
STACK_NAME="${STACK_NAME:-OpenClawEksStack}"
REGION="${AWS_REGION:-us-west-2}"

get_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""
}

CLUSTER_NAME="${CLUSTER_NAME:-$(get_output ClusterName)}"
USER_POOL_ID="${USER_POOL_ID:-$(get_output CognitoPoolId)}"
TENANT_ROLE_ARN="${TENANT_ROLE_ARN:-$(get_output TenantRoleArn)}"

if [[ -z "$CLUSTER_NAME" || -z "$USER_POOL_ID" || -z "$TENANT_ROLE_ARN" ]]; then
  echo "ERROR: Could not resolve required config from CDK stack outputs."
  echo "Set them as environment variables: CLUSTER_NAME, USER_POOL_ID, TENANT_ROLE_ARN"
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }

echo "=== Provisioning tenant: $TENANT ==="
echo "  Email:    $EMAIL"
echo "  Username: $USERNAME"
echo "  NS:       $NS"
echo "  Cluster:  $CLUSTER_NAME"
echo ""

# Step 1: Pod Identity Association
echo "[1/6] Creating Pod Identity Association..."
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --namespace "$NS" \
  --service-account "$TENANT" --role-arn "$TENANT_ROLE_ARN" \
  --region "$REGION" 2>/dev/null || echo "  (already exists, skipping)"

# Step 2: Gateway token -> Secrets Manager
echo "[2/6] Creating gateway token in Secrets Manager..."
TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
SECRET_NAME="openclaw/${TENANT}/gateway-token"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws secretsmanager update-secret --secret-id "$SECRET_NAME" --secret-string "$TOKEN" --region "$REGION" >/dev/null
  echo "  (updated existing secret)"
else
  aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$TOKEN" \
    --tags "Key=tenant,Value=$TENANT" "Key=tenant-namespace,Value=$NS" \
    --region "$REGION" >/dev/null 2>/dev/null || \
  { aws secretsmanager restore-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1
    aws secretsmanager update-secret --secret-id "$SECRET_NAME" --secret-string "$TOKEN" --region "$REGION" >/dev/null; }
  echo "  (created)"
fi

# Step 3: Update Cognito user attributes
echo "[3/6] Updating Cognito user attributes..."
aws cognito-idp admin-update-user-attributes \
  --user-pool-id "$USER_POOL_ID" --username "$USERNAME" \
  --user-attributes "Name=custom:gateway_token,Value=$TOKEN" "Name=custom:tenant_name,Value=$TENANT" \
  --region "$REGION"

# Step 4: Add tenant to ApplicationSet
echo "[4/6] Adding tenant to ApplicationSet..."
APPSET=$(kubectl get applicationset openclaw-tenants -n argocd -o json)
UPDATED=$(echo "$APPSET" | TENANT="$TENANT" EMAIL="$EMAIL" python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    elements = d['spec']['generators'][0]['list']['elements']
    t, e = os.environ['TENANT'], os.environ['EMAIL']
    if not any(el.get('name') == t for el in elements):
        elements.append({'name': t, 'email': e})
    json.dump(d, sys.stdout)
except (KeyError, IndexError, TypeError) as err:
    print(f'ERROR: ApplicationSet has invalid structure: {err}', file=sys.stderr)
    sys.exit(1)
")
echo "$UPDATED" | kubectl apply -f - >/dev/null

# Step 5: Wait for namespace, then create K8s Secret
echo "[5/6] Waiting for namespace and creating gateway secret..."
SECRET_CREATED=false
for i in $(seq 1 15); do
  if kubectl get namespace "$NS" >/dev/null 2>&1; then
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${TENANT}-gateway-token
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: provision-tenant-script
type: Opaque
stringData:
  OPENCLAW_GATEWAY_TOKEN: "$TOKEN"
EOF
    echo "  Secret created in $NS"
    SECRET_CREATED=true
    break
  fi
  echo "  Waiting for namespace $NS... (attempt $i/15)"
  sleep 4
done

if [[ "$SECRET_CREATED" != "true" ]]; then
  echo "ERROR: Namespace $NS was not created within 60s."
  echo "Check: kubectl get applicationset openclaw-tenants -n argocd -o yaml"
  exit 1
fi

# Step 6: Wait for Healthy
echo "[6/6] Waiting for tenant to reach Healthy..."
for i in $(seq 1 30); do
  HEALTH=$(kubectl get application "tenant-$TENANT" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "unknown")
  if [[ "$HEALTH" == "Healthy" ]]; then
    echo ""
    echo "=== Tenant $TENANT is Healthy ==="
    echo "  Workspace URL: https://$(kubectl get gateway openclaw-gateway -n openclaw-system -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null)/t/$TENANT/"
    exit 0
  fi
  echo "  Health: $HEALTH (attempt $i/30)"
  sleep 5
done

echo ""
echo "WARNING: Tenant did not reach Healthy within 150s."
echo "Check: kubectl get application tenant-$TENANT -n argocd -o yaml"
echo "       kubectl get pods -n $NS"
exit 1
