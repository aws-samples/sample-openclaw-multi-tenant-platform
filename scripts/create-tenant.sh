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

# 4. Create K8s Secret with gateway token
echo "  → Creating K8s Secret: ${TENANT}-gateway-token"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "${TENANT}-gateway-token" \
  --namespace "${NAMESPACE}" \
  --from-literal="OPENCLAW_GATEWAY_TOKEN=${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Helm install
echo "  → Helm installing ${RELEASE}"
helm install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --wait --timeout 120s

# 6. Wait for pod Ready
echo "  → Waiting for pod Ready"
kubectl wait pod \
  -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${RELEASE}" \
  --for=condition=Ready \
  --timeout=120s

# 7. Summary
POD=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}')
echo ""
echo "=== Tenant Created ==="
echo "  Namespace:  ${NAMESPACE}"
echo "  Release:    ${RELEASE}"
echo "  Pod:        ${POD}"
echo "  Secret:     ${SECRET_ID}"
echo "  Values:     ${VALUES_FILE}"
echo "======================"
