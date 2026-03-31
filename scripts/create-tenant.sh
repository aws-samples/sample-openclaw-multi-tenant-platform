#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <tenant-name> [--values <file>] [--cluster <name>] [--region <region>] [--skills <s1,s2,...>] [--budget <usd>]"
  exit 1
}

TENANT="" VALUES_FILE="" CLUSTER="openclaw-cluster" REGION="us-west-2"
DISPLAY_NAME="OpenClaw" EMOJI="🦞" SKILLS="weather,gog" BUDGET="100"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES_FILE="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --emoji) EMOJI="$2"; shift 2 ;;
    --skills) SKILLS="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) TENANT="$1"; shift ;;
  esac
done

[[ -z "$TENANT" ]] && usage

NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
SECRET_ID="openclaw/${TENANT}/gateway-token"
ROLE_ARN="${OPENCLAW_TENANT_ROLE_ARN:?Set OPENCLAW_TENANT_ROLE_ARN env var}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="${REPO_DIR}/helm/charts/openclaw-platform"
TEMPLATE="${REPO_DIR}/helm/tenants/values-template.yaml"
TENANT_VALUES="${REPO_DIR}/helm/tenants/values-${TENANT}.yaml"

echo "==> Creating tenant: ${TENANT}"

# 0. Generate tenant values from template
if [[ -z "$VALUES_FILE" ]]; then
  echo "  → Reading config from CDK stack outputs"
  STACK="${OPENCLAW_STACK_NAME:-OpenClawEksStack}"
  get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null; }
  DOMAIN=$(get_output DomainName)
  CERT_ARN=$(get_output CertificateArn)
  COGNITO_POOL_ARN="arn:aws:cognito-idp:${REGION}:$(aws sts get-caller-identity --query Account --output text):userpool/$(get_output CognitoPoolId)"
  COGNITO_CLIENT_ID=$(get_output CognitoClientId)
  COGNITO_DOMAIN=$(get_output CognitoDomain)

  echo "  → Generating ${TENANT_VALUES} from template"
  SKILLS_YAML=""
  IFS=',' read -ra SKILL_ARRAY <<< "${SKILLS}"
  for s in "${SKILL_ARRAY[@]}"; do
    SKILLS_YAML="${SKILLS_YAML}  - ${s}
"
  done
  sed -e "s/{{TENANT}}/${TENANT}/g" \
      -e "s/{{TENANT_DISPLAY_NAME}}/${DISPLAY_NAME}/g" \
      -e "s/{{TENANT_EMOJI}}/${EMOJI}/g" \
      -e "s|{{DOMAIN}}|${DOMAIN}|g" \
      -e "s|{{CERTIFICATE_ARN}}|${CERT_ARN}|g" \
      -e "s|{{COGNITO_POOL_ARN}}|${COGNITO_POOL_ARN}|g" \
      -e "s|{{COGNITO_CLIENT_ID}}|${COGNITO_CLIENT_ID}|g" \
      -e "s|{{COGNITO_DOMAIN}}|${COGNITO_DOMAIN}|g" \
      "${TEMPLATE}" > "${TENANT_VALUES}"
  # Replace multiline placeholder with actual YAML list
  SKILLS_ESCAPED=$(echo "${SKILLS_YAML}" | sed 's/[&/\]/\\&/g; $!s/$/\\/')
  sed -i "s/{{SKILLS_YAML}}/${SKILLS_ESCAPED}/" "${TENANT_VALUES}"
  VALUES_FILE="${TENANT_VALUES}"
fi

# 1. Generate random gateway token
TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# 2. Create secret in Secrets Manager
echo "  → Creating Secrets Manager secret: ${SECRET_ID}"
aws secretsmanager create-secret \
  --region "${REGION}" \
  --name "${SECRET_ID}" \
  --secret-string "${TOKEN}" \
  --tags "Key=tenant-namespace,Value=${NAMESPACE}" "Key=budget-usd,Value=${BUDGET}" \
  --output text --query 'ARN'

# 3. Create Pod Identity Association
echo "  → Creating Pod Identity Association"
aws eks create-pod-identity-association \
  --region "${REGION}" \
  --cluster-name "${CLUSTER}" \
  --namespace "${NAMESPACE}" \
  --service-account "${TENANT}" \
  --role-arn "${ROLE_ARN}" \
  --output text --query 'association.associationId'

# 4. Add Cognito callback URL for this tenant
echo "  → Adding Cognito callback URL"
POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID_COGNITO=$(get_output CognitoClientId)
EXISTING_CALLBACKS=$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID_COGNITO" --region "$REGION" --query 'UserPoolClient.CallbackURLs' --output json)
NEW_CALLBACK="https://${TENANT}.${DOMAIN}/oauth2/idpresponse"
UPDATED_CALLBACKS=$(echo "$EXISTING_CALLBACKS" | python3 -c "import json,sys; urls=json.load(sys.stdin); urls.append('$NEW_CALLBACK') if '$NEW_CALLBACK' not in urls else None; print(' '.join(urls))")
aws cognito-idp update-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID_COGNITO" \
  --callback-urls $UPDATED_CALLBACKS \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO \
  --region "$REGION" > /dev/null

# 5. Helm install
echo "  → Helm installing ${RELEASE}"
helm install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
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
echo "  Values:     ${VALUES_FILE}"
echo "======================"
