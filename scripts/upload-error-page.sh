#!/usr/bin/env bash
set -euo pipefail

REGION="${2:-us-west-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="${SCRIPT_DIR}/../helm/charts/openclaw-platform/static"

# Auto-detect bucket from CDK output if not provided
BUCKET="${1:-$(aws cloudformation describe-stacks --stack-name OpenClawEksStack --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`ErrorPagesBucketName`].OutputValue' --output text 2>/dev/null || echo "")}"

if [ -z "$BUCKET" ]; then
  echo "Usage: $0 [s3-bucket-name] [region]"
  echo "  Or deploy CDK first: the bucket name is auto-detected from stack output"
  exit 1
fi

echo "==> Uploading error pages to s3://${BUCKET}/"
aws s3 cp "${STATIC_DIR}/503.html" "s3://${BUCKET}/503.html" --content-type "text/html" --region "$REGION"

echo ""
echo "=== Uploaded ==="
echo "  URL: https://${BUCKET}.s3.${REGION}.amazonaws.com/503.html"
echo "================"
