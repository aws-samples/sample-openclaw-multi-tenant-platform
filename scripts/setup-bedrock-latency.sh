#!/usr/bin/env bash
set -euo pipefail

CLUSTER="openclaw-cluster"
LOG_GROUP="/aws/containerinsights/${CLUSTER}/application"
REGION="us-west-2"

# SNS topic from CDK stack
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query "Stacks[0].Outputs[?OutputKey=='AlertsTopicArn'].OutputValue" \
  --output text --region "$REGION")

echo "📊 Creating Bedrock latency metric filter..."
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP" \
  --filter-name "BedrockResponseTime" \
  --filter-pattern '{ $.message = "*bedrock*response*" && $.duration = * }' \
  --metric-transformations \
    metricName=BedrockResponseTimeMs,metricNamespace=OpenClaw/Bedrock,metricValue='$.duration',defaultValue=0 \
  --region "$REGION"

echo "🔔 Creating P95 latency alarm (threshold: 10s)..."
aws cloudwatch put-metric-alarm \
  --alarm-name "openclaw-bedrock-p95-latency" \
  --alarm-description "Bedrock P95 response time > 10s" \
  --namespace "OpenClaw/Bedrock" \
  --metric-name "BedrockResponseTimeMs" \
  --statistic p95 \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 10000 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions "$TOPIC_ARN" \
  --treat-missing-data notBreaching \
  --region "$REGION"

echo "✅ Bedrock latency monitoring configured"
echo "   Metric: OpenClaw/Bedrock → BedrockResponseTimeMs"
echo "   Alarm:  P95 > 10s for 2 consecutive 5-min periods → SNS"
