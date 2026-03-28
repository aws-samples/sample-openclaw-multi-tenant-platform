#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <email>"
  exit 1
fi

EMAIL="$1"
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query "Stacks[0].Outputs[?OutputKey=='AlertsTopicArn'].OutputValue" \
  --output text)

aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "$EMAIL"

echo "✅ Subscription request sent to $EMAIL. Check your inbox to confirm."
