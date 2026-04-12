#!/usr/bin/env bash
set -euo pipefail

# Cleanup residual test resources from failed deploys and E2E tests
# Run with: bash scripts/cleanup-test-resources.sh [region]

REGION="${1:-us-west-2}"
STACK=$(aws cloudformation list-stacks --region "$REGION" \
  --query 'StackSummaries[?starts_with(StackName,`OpenClawEksStack`) && StackStatus!=`DELETE_COMPLETE` && !contains(StackName,`NestedStack`)].StackName' \
  --output text 2>/dev/null | head -1)
[[ -z "$STACK" || "$STACK" == "None" ]] && STACK="OpenClawEksStack"
DRY_RUN="${DRY_RUN:-true}"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""; }

echo "==> Cleanup test resources (DRY_RUN=${DRY_RUN})"
echo "  Region: ${REGION}"
echo ""

# 1. Clean up test tenant secrets
echo ""
echo "==> Checking for test tenant secrets..."
TEST_NAMES=(e2etest4 stubbly2887 e2e final test e2efinal sloppy7268 demo)
for name in "${TEST_NAMES[@]}"; do
  SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "openclaw/${name}/api-key" --region "$REGION" --query 'ARN' --output text 2>/dev/null || echo "")
  if [ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ]; then
    echo "  FOUND: openclaw/${name}/api-key"
    if [ "$DRY_RUN" = "false" ]; then
      aws secretsmanager delete-secret --secret-id "openclaw/${name}/api-key" --force-delete-without-recovery --region "$REGION" && echo "    Deleted" || echo "    Failed"
    fi
  fi
done

echo ""
if [ "$DRY_RUN" = "true" ]; then
  echo "=== DRY RUN complete. Set DRY_RUN=false to execute deletions ==="
else
  echo "=== Cleanup complete ==="
fi
