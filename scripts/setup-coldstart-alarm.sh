#!/usr/bin/env bash
set -euo pipefail

CLUSTER="openclaw-cluster"
LOG_GROUP="/aws/containerinsights/${CLUSTER}/performance"
REGION="us-west-2"

TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query "Stacks[0].Outputs[?OutputKey=='AlertsTopicArn'].OutputValue" \
  --output text --region "$REGION")

echo "📊 Creating cold start metric filter..."
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP" \
  --filter-name "PodStartupDuration" \
  --filter-pattern '{ $.Type = "Pod" && $.PodStatus = "Running" && $.pod_startup_duration_seconds = * }' \
  --metric-transformations \
    metricName=PodStartupDurationSeconds,metricNamespace=OpenClaw/ColdStart,metricValue='$.pod_startup_duration_seconds',defaultValue=0 \
  --region "$REGION"

echo "🔔 Creating cold start alarm (threshold: 60s)..."
aws cloudwatch put-metric-alarm \
  --alarm-name "openclaw-pod-coldstart-slow" \
  --alarm-description "Pod startup time > 60s (cold start too slow)" \
  --namespace "OpenClaw/ColdStart" \
  --metric-name "PodStartupDurationSeconds" \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 60 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions "$TOPIC_ARN" \
  --treat-missing-data notBreaching \
  --region "$REGION"

echo "✅ Cold start alarm configured"
echo "   Metric: OpenClaw/ColdStart → PodStartupDurationSeconds"
echo "   Alarm:  Max > 60s in any 5-min period → SNS"
