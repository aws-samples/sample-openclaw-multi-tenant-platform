#!/usr/bin/env bash
set -euo pipefail

REGION="us-west-2"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Usage: $0 [--region REGION]"; exit 1 ;;
  esac
done

LOG_GROUP="/aws/containerinsights/openclaw-cluster/application"
NAMESPACE="OpenClaw/Usage"
TENANTS=(alice bob carol)

# Step 1: Metric Filters
echo "📊 建立 metric filters..."
aws logs put-metric-filter --region "$REGION" \
  --log-group-name "$LOG_GROUP" \
  --filter-name openclaw-token-usage \
  --filter-pattern '{ $.input_tokens = * }' \
  --metric-transformations \
    "metricName=BedrockInputTokens,metricNamespace=$NAMESPACE,metricValue=\$.input_tokens" \
    "metricName=BedrockOutputTokens,metricNamespace=$NAMESPACE,metricValue=\$.output_tokens"
echo "✅ Metric filters 建立完成"

# Step 2: Dashboard
echo "📈 建立 dashboard..."
WIDGETS=""
Y=0
for T in "${TENANTS[@]}"; do
  NS="openclaw-${T}"
  [[ -n "$WIDGETS" ]] && WIDGETS="${WIDGETS},"
  WIDGETS="${WIDGETS}
    {\"type\":\"metric\",\"x\":0,\"y\":${Y},\"width\":12,\"height\":6,\"properties\":{\"title\":\"${T} - Input Tokens\",\"metrics\":[[\"${NAMESPACE}\",\"BedrockInputTokens\",{\"label\":\"${NS}\"}]],\"stat\":\"Sum\",\"period\":86400,\"region\":\"${REGION}\"}},
    {\"type\":\"metric\",\"x\":12,\"y\":${Y},\"width\":12,\"height\":6,\"properties\":{\"title\":\"${T} - Output Tokens\",\"metrics\":[[\"${NAMESPACE}\",\"BedrockOutputTokens\",{\"label\":\"${NS}\"}]],\"stat\":\"Sum\",\"period\":86400,\"region\":\"${REGION}\"}}"
  Y=$((Y + 6))
done

aws cloudwatch put-dashboard --region "$REGION" \
  --dashboard-name OpenClaw-Usage \
  --dashboard-body "{\"widgets\":[${WIDGETS}]}"
echo "✅ Dashboard OpenClaw-Usage 建立完成"
