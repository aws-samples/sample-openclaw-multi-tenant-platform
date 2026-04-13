#!/usr/bin/env bash
# Full deployment pipeline — run this single script to deploy the entire platform.
#
# Usage:
#   REGION=us-east-1 bash scripts/deploy-all.sh          # no custom domain
#   REGION=us-west-2 bash scripts/deploy-all.sh          # with custom domain (set in cdk.json)
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - kubectl installed
#   - helm installed
#   - CDK CLI >= 2.1114.1 (run: npm install -g aws-cdk)
#   - Node.js >= 18
#   - cdk/cdk.json configured with your values (copy from cdk.json.example)
#
# What this does (in order):
#   1. cdk deploy         — EKS cluster, Cognito, CloudFront, EFS, etc. (~20 min)
#   2. ArgoCD install      — GitOps controller for tenant management
#   3. deploy-platform.sh — ApplicationSet + Gateway API resources
#   4. setup-keda.sh      — KEDA + HTTP add-on for scale-to-zero
#   5. post-deploy.sh     — CloudFront ALB origin + Route53 (if custom domain)
#   6. Smoke test         — Verify auth UI is reachable
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
CDK_DIR="$REPO_ROOT/cdk"

# Region: explicit > AWS_REGION > profile default
REGION="${REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
export AWS_REGION="$REGION"
export CDK_DEFAULT_REGION="$REGION"
export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}"

echo "============================================"
echo "  OpenClaw Platform — Full Deployment"
echo "  Region:  $REGION"
echo "  Account: $CDK_DEFAULT_ACCOUNT"
echo "============================================"
echo ""

# ── Pre-flight checks ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"

for cmd in aws kubectl helm node cdk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found. Install it first."
    exit 1
  fi
done

CDK_VERSION=$(cdk --version 2>/dev/null | awk '{print $1}')
REQUIRED_CDK="2.1114.1"
if [ "$(printf '%s\n' "$REQUIRED_CDK" "$CDK_VERSION" | sort -V | head -n1)" != "$REQUIRED_CDK" ]; then
  echo "ERROR: CDK CLI version $CDK_VERSION is too old. Need >= $REQUIRED_CDK"
  echo "  Run: npm install -g aws-cdk"
  exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS credentials not configured. Run: aws configure"
  exit 1
fi

if [ ! -f "$CDK_DIR/cdk.json" ]; then
  echo "ERROR: cdk/cdk.json not found. Copy from cdk.json.example and fill in your values."
  exit 1
fi

echo "  All checks passed."
echo ""

# ── Step 1: CDK Deploy ─────────────────────────────────────────────────────
echo "==> Step 1/6: CDK Deploy (~20 minutes)"
cd "$CDK_DIR"
npm install --silent 2>/dev/null
cdk bootstrap --quiet 2>/dev/null || true  # idempotent, no-op if already bootstrapped
cdk deploy --require-approval never
cd "$REPO_ROOT"

# Get kubeconfig — read cluster name from stack outputs (dynamic per deployment)
source "$SCRIPTS_DIR/lib/common.sh"
CLUSTER_NAME="$CLUSTER"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
echo "  Kubeconfig updated for $CLUSTER_NAME"

echo ""

# ── Step 2: ArgoCD ──────────────────────────────────────────────────────────
echo "==> Step 2/6: Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts 2>&1 | tail -1
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=120s
echo "  ArgoCD ready."
echo ""

# ── Step 3: Platform (ApplicationSet + Gateway) ────────────────────────────
echo "==> Step 3/6: Deploying platform resources"
bash "$SCRIPTS_DIR/deploy-platform.sh"
echo ""

# ── Step 4: KEDA + HTTP Add-on ──────────────────────────────────────────────
echo "==> Step 4/6: Installing KEDA"
bash "$SCRIPTS_DIR/setup-keda.sh"
echo ""

# ── Step 5: Post-deploy (CloudFront ALB + Route53) ──────────────────────────
echo "==> Step 5/6: Post-deploy setup"

# Wait for ALB to be created by Gateway controller
echo "  Waiting for ALB to be provisioned..."
for i in $(seq 1 30); do
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')].DNSName" \
    --output text 2>/dev/null)
  if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
    echo "  ALB ready: $ALB_DNS"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "  WARNING: ALB not ready after 5 min. Run post-deploy.sh manually later."
    exit 0
  fi
  sleep 10
done

bash "$SCRIPTS_DIR/post-deploy.sh"
echo ""

# ── Step 6: Verify & fix Cognito settings ───────────────────────────────────
echo "==> Step 6/6: Verifying Cognito configuration"
source "$SCRIPTS_DIR/lib/common.sh"
POOL_ID=$(get_output CognitoPoolId)
DOMAIN=$(get_output DomainName)

# CloudFormation sometimes does not apply AllowAdminCreateUserOnly=false correctly.
# Verify and fix if needed — this is idempotent and safe.
ADMIN_ONLY=$(aws cognito-idp describe-user-pool --user-pool-id "$POOL_ID" --region "$REGION" \
  --query "UserPool.AdminCreateUserConfig.AllowAdminCreateUserOnly" --output text)
if [ "$ADMIN_ONLY" = "True" ] || [ "$ADMIN_ONLY" = "true" ]; then
  echo "  Fixing: self-signup was disabled, enabling..."
  # Preserve existing LambdaConfig and AutoVerifiedAttributes
  LAMBDA_CONFIG=$(aws cognito-idp describe-user-pool --user-pool-id "$POOL_ID" --region "$REGION" \
    --query "UserPool.LambdaConfig" --output json)
  aws cognito-idp update-user-pool --user-pool-id "$POOL_ID" --region "$REGION" \
    --admin-create-user-config AllowAdminCreateUserOnly=false \
    --auto-verified-attributes email \
    --lambda-config "$LAMBDA_CONFIG"
  echo "  Self-signup enabled."
else
  echo "  Self-signup: OK"
fi
echo ""

# ── Health check ────────────────────────────────────────────────────────────
echo "==> Health check"
AUTH_URL="https://${DOMAIN}/auth/"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$AUTH_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  Auth UI ($AUTH_URL): OK"
else
  echo "  WARNING: Auth UI returned HTTP $HTTP_CODE. CloudFront may still be deploying (~3 min)."
fi
echo ""

echo "============================================"
echo "  Deployment Complete!"
echo ""
echo "  Auth UI: https://${DOMAIN}/auth/"
echo "  Region:  $REGION"
echo ""
echo "  Test sign-up with an @$(node -e "console.log(require('$CDK_DIR/cdk.json').context.allowedEmailDomains || 'example.com')") email"
echo "============================================"
