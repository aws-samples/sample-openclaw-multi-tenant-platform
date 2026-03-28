#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

WAF_ARN=$(get_output WafAclArn)

# Find ALB ARN by IngressGroup tag
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, 'openclawshared')].LoadBalancerArn" --output text)

if [ -z "$ALB_ARN" ]; then
  echo "Error: ALB not found. Create at least one tenant first."
  exit 1
fi

echo "==> Attaching WAF to ALB"
echo "  WAF: $WAF_ARN"
echo "  ALB: $ALB_ARN"

aws wafv2 associate-web-acl \
  --web-acl-arn "$WAF_ARN" \
  --resource-arn "$ALB_ARN" \
  --region "$REGION" 2>&1

echo "✅ WAF attached to ALB"
