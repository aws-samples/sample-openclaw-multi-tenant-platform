#!/usr/bin/env bash
# Deploy platform resources: ApplicationSet + Gateway API
# Usage: bash scripts/deploy-platform.sh
#
# Reads all config from CloudFormation stack outputs (not cdk.json).
# This allows parallel multi-region deploys without cdk.json conflicts.
#   1. ApplicationSet (multi-tenant ArgoCD generator)
#   2. Gateway API resources (GatewayClass + LoadBalancerConfiguration + Gateway)
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# Region: prefer AWS_REGION env, then extract from EKS cluster endpoint URL
if [ -z "${AWS_REGION:-}" ]; then
  _EKS_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  REGION=$(echo "$_EKS_URL" | sed -n 's|.*\.\([a-z]*-[a-z]*-[0-9]*\)\.eks\..*|\1|p')
  REGION="${REGION:-us-west-2}"
else
  REGION="$AWS_REGION"
fi

echo "==> Reading config from stack outputs"
STACK="OpenClawEksStack"

get_stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

DOMAIN=$(get_stack_output DomainName)
CUSTOM_DOMAIN=$(get_stack_output CustomDomain)
CERT_ARN=$(get_stack_output CertificateArn)
COGNITO_POOL_ID=$(get_stack_output CognitoPoolId)
COGNITO_CLIENT_ID=$(get_stack_output CognitoClientId)
COGNITO_DOMAIN=$(get_stack_output CognitoDomain)

if [ -n "$COGNITO_POOL_ID" ]; then
  COGNITO_POOL_ARN="arn:aws:cognito-idp:${REGION}:${ACCOUNT}:userpool/${COGNITO_POOL_ID}"
fi

# githubOwner/Repo: from stack outputs (added by CDK), fallback to cdk.json for backward compat
GITHUB_OWNER=$(get_stack_output GithubOwner)
GITHUB_REPO=$(get_stack_output GithubRepo)
if [[ -z "$GITHUB_OWNER" ]]; then
  CDK_JSON="cdk/cdk.json"
  if [[ -f "$CDK_JSON" ]]; then
    GITHUB_OWNER=$(node -e "console.log(require('./$CDK_JSON').context.githubOwner || 'aws-samples')")
    GITHUB_REPO=$(node -e "console.log(require('./$CDK_JSON').context.githubRepo || 'openclaw-platform')")
  else
    GITHUB_OWNER="${GITHUB_OWNER:-aws-samples}"
    GITHUB_REPO="${GITHUB_REPO:-openclaw-platform}"
  fi
fi

for var_name in GITHUB_OWNER GITHUB_REPO COGNITO_POOL_ARN COGNITO_CLIENT_ID COGNITO_DOMAIN DOMAIN; do
  val="${!var_name}"
  if [[ -z "$val" ]]; then
    echo "Error: $var_name is empty. Check stack outputs: aws cloudformation describe-stacks --stack-name $STACK --region $REGION"
    exit 1
  fi
done

echo "  Domain: $DOMAIN (custom=$CUSTOM_DOMAIN)"

CHART_REPO="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

# Determine listener mode: custom domain with cert → HTTPS, otherwise HTTP
if [ "$CUSTOM_DOMAIN" = "true" ] && [ -n "$CERT_ARN" ]; then
  LISTENER_NAME="https"
else
  LISTENER_NAME="http"
fi

echo "==> Deploying ApplicationSet (patching placeholders)"
sed \
  -e "s|\"HELM_REPO_URL\"|\"${CHART_REPO}\"|g" \
  -e "s|\"DOMAIN\"|\"${DOMAIN}\"|g" \
  -e "s|\"LISTENER_NAME\"|\"${LISTENER_NAME}\"|g" \
  -e "s|\"COGNITO_POOL_ARN\"|\"${COGNITO_POOL_ARN}\"|g" \
  -e "s|\"COGNITO_CLIENT_ID\"|\"${COGNITO_CLIENT_ID}\"|g" \
  -e "s|\"COGNITO_DOMAIN\"|\"${COGNITO_DOMAIN}\"|g" \
  -e "s|\"BEDROCK_REGION\"|\"${REGION}\"|g" \
  helm/applicationset.yaml | kubectl apply -f -

echo "==> Installing Gateway API CRDs (required by ALB Controller)"
# ALB Controller v3.x requires ListenerSet CRD which is only in experimental channel.
# Use server-side apply to handle large CRD annotations that exceed client-side limits.
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=30s || echo "  (CRDs already established)"

# ALB Controller v3.x expects ListenerSet in the GA API group (gateway.networking.k8s.io/v1)
# but Gateway API only ships it in the experimental group (gateway.networking.x-k8s.io).
# Create a stub CRD to satisfy the controller's startup check.
echo "==> Creating ListenerSet stub CRD (required by ALB Controller v3.x)"
kubectl apply -f - <<'LISTENERSET'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: listenersets.gateway.networking.k8s.io
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api/pull/3883"
  labels:
    app.kubernetes.io/managed-by: deploy-platform
spec:
  group: gateway.networking.k8s.io
  names:
    kind: ListenerSet
    listKind: ListenerSetList
    plural: listenersets
    singular: listenerset
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
          status:
            type: object
            x-kubernetes-preserve-unknown-fields: true
LISTENERSET

# Grant ALB Controller RBAC to watch ListenerSet resources
echo "==> Granting ALB Controller RBAC for ListenerSet"
kubectl apply -f - <<'RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alb-controller-listenerset
  labels:
    app.kubernetes.io/managed-by: deploy-platform
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["listenersets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alb-controller-listenerset
  labels:
    app.kubernetes.io/managed-by: deploy-platform
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alb-controller-listenerset
subjects:
- kind: ServiceAccount
  name: aws-load-balancer-controller
  namespace: kube-system
RBAC

# ALB Controller checks for Gateway API CRDs at startup. If CRDs were installed
# after the controller started (e.g., CDK deploys controller before this script
# installs CRDs), the controller disables Gateway API support. Restart it so it
# picks up the newly installed CRDs.
echo "==> Restarting ALB Controller to detect Gateway API CRDs"
kubectl rollout restart deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl rollout status deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --timeout=120s

echo "==> Ensuring openclaw-system namespace (with Pod Security Standards)"
kubectl apply -f - <<'NS'
apiVersion: v1
kind: Namespace
metadata:
  name: openclaw-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
NS

echo "==> Deploying Gateway API resources (patching domain + prefix list)"
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text --region "${REGION}")
if [ -z "$CF_PREFIX_LIST" ] || [ "$CF_PREFIX_LIST" = "None" ]; then
  echo "ERROR: Could not find CloudFront managed prefix list in ${REGION}"
  exit 1
fi

# Check if custom domain has an ACM cert (needed for HTTPS listener on ALB)
if [ "$CUSTOM_DOMAIN" = "true" ] && [ -n "$CERT_ARN" ]; then
  # Custom domain with ACM cert — HTTPS listener
  echo "  Gateway: HTTPS listener on ${DOMAIN}"
  sed \
    -e "s|\"DOMAIN\"|\"${DOMAIN}\"|g" \
    -e "s|\"CF_PREFIX_LIST_ID\"|\"${CF_PREFIX_LIST}\"|g" \
    helm/gateway.yaml | kubectl apply -f -
else
  # No custom domain or no cert — HTTP listener (CloudFront handles TLS termination)
  # Use python for reliable YAML manipulation instead of fragile sed
  if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: python3 + pyyaml required for no-domain mode. Install: pip3 install pyyaml"
    exit 1
  fi
  echo "  Gateway: HTTP listener (no custom domain, CloudFront terminates TLS)"
  python3 - "$CF_PREFIX_LIST" <<'PYEOF' | kubectl apply -f -
import yaml, sys
prefix_list = sys.argv[1]
with open('helm/gateway.yaml') as f:
    docs = list(yaml.safe_load_all(f))
output = []
for doc in docs:
    if not doc:
        continue
    if doc.get('kind') == 'Gateway':
        doc['spec']['listeners'] = [{
            'name': 'http',
            'protocol': 'HTTP',
            'port': 80,
            'allowedRoutes': {'namespaces': {'from': 'All'}}
        }]
    if doc.get('kind') == 'LoadBalancerConfiguration':
        doc['spec']['securityGroupPrefixes'] = [prefix_list]
    output.append(yaml.dump(doc, default_flow_style=False))
print('---\n'.join(output))
PYEOF
fi

echo ""
echo "=== Platform Deployed ==="
echo "  ApplicationSet: openclaw-tenants (in argocd namespace)"
echo "  Gateway: openclaw-gateway (in openclaw-system namespace)"
echo ""
echo "  Next: create a tenant with scripts/create-tenant.sh"
echo "========================"
