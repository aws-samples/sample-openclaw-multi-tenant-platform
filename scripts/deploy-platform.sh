#!/usr/bin/env bash
# Deploy platform resources: ApplicationSet + Gateway API
# Usage: bash scripts/deploy-platform.sh
#
# Reads cdk/cdk.json for configuration, injects values via sed, and applies:
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

echo "==> Reading config from cdk.json"
CDK_JSON="cdk/cdk.json"
if [[ -f "$CDK_JSON" ]]; then
  DOMAIN=$(node -e "console.log(require('./$CDK_JSON').context.zoneName || '')")
  GITHUB_OWNER=$(node -e "console.log(require('./$CDK_JSON').context.githubOwner || '')")
  GITHUB_REPO=$(node -e "console.log(require('./$CDK_JSON').context.githubRepo || '')")
  COGNITO_POOL_ARN=$(node -e "const c=require('./$CDK_JSON').context; const id=c.cognitoPoolId||''; const r='${REGION}'; const a=c.accountId||'${ACCOUNT}'; console.log(id ? 'arn:aws:cognito-idp:'+r+':'+a+':userpool/'+id : '')")
  COGNITO_CLIENT_ID=$(node -e "console.log(require('./$CDK_JSON').context.cognitoClientId || '')")
  COGNITO_DOMAIN=$(node -e "console.log(require('./$CDK_JSON').context.cognitoDomain || '')")
else
  echo "Error: cdk/cdk.json not found."
  exit 1
fi

for var_name in DOMAIN GITHUB_OWNER GITHUB_REPO COGNITO_POOL_ARN COGNITO_CLIENT_ID COGNITO_DOMAIN; do
  val="${!var_name}"
  if [[ -z "$val" ]]; then
    echo "Error: $var_name is empty in cdk.json."
    exit 1
  fi
done

CHART_REPO="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

echo "==> Deploying ApplicationSet (patching placeholders)"
sed \
  -e "s|\"HELM_REPO_URL\"|\"${CHART_REPO}\"|g" \
  -e "s|\"DOMAIN\"|\"${DOMAIN}\"|g" \
  -e "s|\"COGNITO_POOL_ARN\"|\"${COGNITO_POOL_ARN}\"|g" \
  -e "s|\"COGNITO_CLIENT_ID\"|\"${COGNITO_CLIENT_ID}\"|g" \
  -e "s|\"COGNITO_DOMAIN\"|\"${COGNITO_DOMAIN}\"|g" \
  -e "s|\"BEDROCK_REGION\"|\"${REGION}\"|g" \
  helm/applicationset.yaml | kubectl apply -f -

echo "==> Installing Gateway API CRDs (required by ALB Controller)"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=30s || echo "  (CRDs already established)"

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
sed \
  -e "s|\"DOMAIN\"|\"${DOMAIN}\"|g" \
  -e "s|\"CF_PREFIX_LIST_ID\"|\"${CF_PREFIX_LIST}\"|g" \
  helm/gateway.yaml | kubectl apply -f -

echo ""
echo "=== Platform Deployed ==="
echo "  ApplicationSet: openclaw-tenants (in argocd namespace)"
echo "  Gateway: openclaw-gateway (in openclaw-system namespace)"
echo ""
echo "  Next: create a tenant with scripts/create-tenant.sh"
echo "========================"
