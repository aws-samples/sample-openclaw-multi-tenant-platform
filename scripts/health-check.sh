#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
STATUS="healthy"
COMPONENTS="{}"

check() {
  local name="$1" cmd="$2"
  local result
  if result=$(eval "$cmd" 2>&1); then
    COMPONENTS=$(echo "$COMPONENTS" | jq --arg k "$name" --arg v "ok" '. + {($k): $v}')
  else
    COMPONENTS=$(echo "$COMPONENTS" | jq --arg k "$name" --arg v "fail: $(echo "$result" | head -1)" '. + {($k): $v}')
    STATUS="unhealthy"
  fi
}

# KEDA pods
check "keda" "kubectl get pods -n keda --no-headers 2>/dev/null | grep -v Running && exit 1 || true"

# PVCs
check "pvc" "kubectl get pvc -A -l app.kubernetes.io/name=openclaw-helm --no-headers 2>/dev/null | grep -v Bound && exit 1 || true"

# ALB health (internal, best-effort)
ALB_DNS=$(kubectl get ingress -A -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$ALB_DNS" ]; then
  check "alb" "curl -sf -o /dev/null -w '%{http_code}' --max-time 5 http://${ALB_DNS}/healthz || exit 1"
else
  COMPONENTS=$(echo "$COMPONENTS" | jq '. + {"alb": "skip: no ingress found"}')
fi

# CloudFront
CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[0].Id" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
  check "cloudfront" "aws cloudfront get-distribution --id $CF_ID --query 'Distribution.Status' --output text --region $REGION | grep -q Deployed"
else
  COMPONENTS=$(echo "$COMPONENTS" | jq '. + {"cloudfront": "skip: not found"}')
fi

# WAF
check "waf" "aws wafv2 list-web-acls --scope REGIONAL --region $REGION --query 'WebACLs[0].Name' --output text | grep -v None"

jq -n --arg s "$STATUS" --argjson c "$COMPONENTS" '{"status": $s, "components": $c}'
