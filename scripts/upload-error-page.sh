#!/usr/bin/env bash
set -euo pipefail

BUCKET="${1:?Usage: $0 <s3-bucket-name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../helm/charts/openclaw-platform/static/503.html"

aws s3 cp "$SRC" "s3://${BUCKET}/503.html" --content-type "text/html"

echo "✅ 已上傳 503.html → s3://${BUCKET}/503.html"
echo ""
echo "ALB custom error page 設定指引："
echo "  1. AWS Console → EC2 → Load Balancers → 選擇 ALB"
echo "  2. Listeners → 編輯 Rules"
echo "  3. 加入 Fixed Response 或 Custom Error Page rule："
echo "     - Condition: HTTP status = 503"
echo "     - Action: Return custom response from S3"
echo "     - S3 URI: s3://${BUCKET}/503.html"
echo "  4. 或透過 ALB Ingress annotation："
echo "     alb.ingress.kubernetes.io/actions.custom-error: |"
echo "       {\"type\":\"fixed-response\",\"fixedResponseConfig\":{\"contentType\":\"text/html\",\"statusCode\":\"503\",\"messageBody\":\"<503.html content>\"}}"
