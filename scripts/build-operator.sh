#!/usr/bin/env bash
# Build, push, and deploy the Tenant Operator to EKS
# Usage: bash scripts/build-operator.sh
set -euo pipefail

REPO_NAME="openclaw-tenant-operator"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-west-2}")
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Creating ECR repository (idempotent)"
aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" 2>/dev/null || true

echo "==> Logging in to ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

echo "==> Building operator image"
docker build -t "${REPO_NAME}:latest" operator/

echo "==> Tagging and pushing"
docker tag "${REPO_NAME}:latest" "${ECR}/${REPO_NAME}:latest"
docker push "${ECR}/${REPO_NAME}:latest"

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
  echo "Error: cdk/cdk.json not found. Cannot deploy without configuration."
  echo "Create cdk/cdk.json with context values: zoneName, githubOwner, githubRepo, cognitoPoolId, cognitoClientId, cognitoDomain"
  exit 1
fi

# Validate required values — fail early instead of deploying placeholders
for var_name in DOMAIN GITHUB_OWNER GITHUB_REPO; do
  eval val=\$$var_name
  if [[ -z "$val" ]]; then
    echo "Error: $var_name is empty in cdk.json. Cannot deploy with placeholder values."
    exit 1
  fi
done

CHART_REPO="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

echo "==> Applying CRD"
kubectl apply -f operator/yaml/crd.yaml

echo "==> Deploying operator (patching placeholders)"
sed \
  -e "s|\"REGION\"|\"${REGION}\"|g" \
  -e "s|value: \"DOMAIN\"|value: \"${DOMAIN}\"|g" \
  -e "s|value: \"COGNITO_POOL_ARN\"|value: \"${COGNITO_POOL_ARN}\"|g" \
  -e "s|value: \"COGNITO_CLIENT_ID\"|value: \"${COGNITO_CLIENT_ID}\"|g" \
  -e "s|value: \"COGNITO_DOMAIN\"|value: \"${COGNITO_DOMAIN}\"|g" \
  -e "s|https://github.com/ORG/REPO.git|${CHART_REPO}|g" \
  operator/yaml/deployment.yaml | kubectl apply -f -

echo "==> Waiting for operator pod"
kubectl rollout status deployment/tenant-operator -n openclaw-system --timeout=120s

echo "==> Done. Operator running:"
kubectl get pods -n openclaw-system -l app=tenant-operator
