#!/usr/bin/env bash
set -euo pipefail

# Cleanup residual test resources from failed deploys and E2E tests
# Run with: bash scripts/cleanup-test-resources.sh [region]

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"
DRY_RUN="${DRY_RUN:-true}"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""; }

echo "==> Cleanup test resources (DRY_RUN=${DRY_RUN})"
echo "  Region: ${REGION}"
echo ""

# 1. Identify active ErrorPages bucket from CloudFormation
ACTIVE_BUCKET=$(get_output ErrorPagesBucketName)
if [ -z "$ACTIVE_BUCKET" ]; then
  echo "ERROR: Could not identify active ErrorPages bucket from CloudFormation stack '$STACK'"
  echo "ERROR: Cannot proceed with S3 cleanup - risk of deleting active resources"
  echo "  Skipping S3 cleanup, continuing with secrets cleanup..."
  echo ""
else
  echo "==> Active ErrorPages bucket: ${ACTIVE_BUCKET}"

  # 2. List orphan ErrorPages buckets
  echo ""
  echo "==> Checking for orphan S3 ErrorPages buckets..."
  aws s3api list-buckets --query 'Buckets[?contains(Name,`errorpages`) || contains(Name,`ErrorPages`)].Name' --output text | tr '\t' '\n' | while read -r bucket; do
    [ -z "$bucket" ] && continue
    if [ "$bucket" != "$ACTIVE_BUCKET" ]; then
      echo "  ORPHAN: $bucket"
      if [ "$DRY_RUN" = "false" ]; then
        aws s3 rb "s3://${bucket}" --force --region "$REGION" && echo "    Deleted" || echo "    Failed (may need manual cleanup)"
      fi
    else
      echo "  ACTIVE: $bucket (skip)"
    fi
  done
fi

# 3. Clean up test tenant secrets
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
