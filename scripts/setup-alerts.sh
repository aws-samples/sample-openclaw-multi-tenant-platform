#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <email>"
  exit 1
fi

EMAIL="$1"
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name EksClusterStack \
  --query "Stacks[0].Outputs[?OutputKey=='AlertsTopicArn'].OutputValue" \
  --output text)

aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "$EMAIL"

echo "✅ 已送出訂閱請求到 $EMAIL，請去信箱確認。"
