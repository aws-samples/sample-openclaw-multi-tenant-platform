#!/usr/bin/env bash
# Create first tenant and automatically run post-deploy.sh
# Usage: ./scripts/create-first-tenant.sh <name> --email <email>
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

SCRIPT_DIR="$(dirname "$0")"

usage() {
  echo "Usage: $0 <tenant-name> [--email <email>]"
  echo ""
  echo "This script:"
  echo "  1. Creates the first tenant"
  echo "  2. Waits for ALB to be created by ALB Controller"
  echo "  3. Automatically runs post-deploy.sh"
  echo ""
  echo "This is safer than running create-tenant.sh + post-deploy.sh separately"
  echo "because users often forget the post-deploy.sh step."
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

echo "==> Creating first tenant with auto post-deploy"
echo "  Tenant: ${TENANT}"
echo "  Email: ${EMAIL}"
echo ""

# Step 1: Create tenant
echo "Step 1/3: Creating tenant..."
bash "$SCRIPT_DIR/create-tenant.sh" "$TENANT" --email "$EMAIL"

# Step 2: Wait for ALB to exist
echo ""
echo "Step 2/3: Waiting for ALB Controller to create ALB..."
echo "  This can take 2-5 minutes..."

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
timeout=300  # 5 minutes
elapsed=0
interval=15

while [ $elapsed -lt $timeout ]; do
  ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null || echo "")

  if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    echo "  ✅ ALB found: $ALB_ARN"
    break
  fi

  echo "  ⏳ Waiting for ALB... (${elapsed}s/${timeout}s)"
  sleep $interval
  elapsed=$((elapsed + interval))
done

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  echo "  ❌ Timeout waiting for ALB creation"
  echo ""
  echo "Manual steps to complete setup:"
  echo "  1. Wait for ALB to appear:"
  echo "     aws elbv2 describe-load-balancers --query \"LoadBalancers[?contains(LoadBalancerName,'openclaw')]\""
  echo "  2. Run: ./scripts/post-deploy.sh"
  exit 1
fi

# Step 3: Run post-deploy
echo ""
echo "Step 3/3: Running post-deploy.sh..."
bash "$SCRIPT_DIR/post-deploy.sh"

echo ""
echo "🎉 First tenant setup complete!"
echo ""
echo "Next steps:"
echo "  1. Verify deployment:"
echo "     ./scripts/health-check.sh"
echo "  2. Get access URL:"
DOMAIN=$(get_output DomainName 2>/dev/null || echo "unknown")
echo "     https://${DOMAIN}/t/${TENANT}/"
echo "  3. Create additional tenants:"
echo "     ./scripts/create-tenant.sh <name> --email <email>"
echo "     (post-deploy.sh only needs to run once)"