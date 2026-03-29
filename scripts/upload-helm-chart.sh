#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null; }

BUCKET=$(get_output ErrorPagesBucketName)
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/helm/charts/openclaw-platform"

echo "==> Packaging Helm chart"
helm package "$CHART_DIR" -d /tmp/ 2>&1 | tail -1
CHART_FILE=$(ls /tmp/openclaw-helm-*.tgz 2>/dev/null | head -1)

echo "==> Uploading to s3://${BUCKET}/"
aws s3 cp "$CHART_FILE" "s3://${BUCKET}/openclaw-platform.tgz" --region "$REGION"
# Also upload a dummy source for CodeBuild (it needs at least one file)
echo '{}' > /tmp/buildspec-placeholder.json
aws s3 cp /tmp/buildspec-placeholder.json "s3://${BUCKET}/codebuild/buildspec-placeholder.json" --region "$REGION"

rm -f "$CHART_FILE" /tmp/buildspec-placeholder.json
echo "✅ Chart uploaded"
