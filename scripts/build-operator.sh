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
else
  echo "Warning: cdk/cdk.json not found, using placeholders for env vars"
  DOMAIN="DOMAIN"
  GITHUB_OWNER="ORG"
  GITHUB_REPO="REPO"
fi

CHART_REPO="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

echo "==> Applying CRD"
kubectl apply -f operator/yaml/crd.yaml

echo "==> Deploying operator (patching placeholders)"
sed \
  -e "s|ACCOUNT_ID\.dkr\.ecr\.REGION\.amazonaws\.com|${ECR}|g" \
  -e "s|ACCOUNT_ID|${ACCOUNT}|g" \
  -e "s|\"REGION\"|\"${REGION}\"|g" \
  -e "s|value: \"DOMAIN\"|value: \"${DOMAIN}\"|g" \
  -e "s|https://github.com/ORG/REPO.git|${CHART_REPO}|g" \
  operator/yaml/deployment.yaml | kubectl apply -f -

echo "==> Waiting for operator pod"
kubectl rollout status deployment/tenant-operator -n openclaw-system --timeout=120s

echo "==> Done. Operator running:"
kubectl get pods -n openclaw-system -l app=tenant-operator
