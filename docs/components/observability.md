# Observability -- Monitoring, Alerting, and Cost Tracking

## CloudWatch Container Insights

Deployed as Amazon EKS addon (`amazon-cloudwatch-observability`) via AWS CDK. Uses Pod Identity with `CloudWatchAgentServerPolicy` + `AWSXrayWriteOnlyAccess`.

Collects pod stdout to CloudWatch Logs -- foundation for usage tracking and custom metrics.

Log groups:
- `/aws/containerinsights/openclaw-cluster/application` -- application logs (token usage)
- `/aws/containerinsights/openclaw-cluster/performance` -- pod lifecycle metrics (cold start)

## CloudWatch Alarms

All alarms publish to the `OpenClawAlerts` SNS topic.

| Alarm | Metric | Condition | Setup |
|---|---|---|---|
| `OpenClaw-PodRestartCount` | `ContainerInsights/pod_number_of_container_restarts` | Sum > 0 in 5 min | AWS CDK (automatic) |
| `openclaw-bedrock-p95-latency` | `OpenClaw/Amazon Bedrock/BedrockResponseTimeMs` | P95 > 10s for 2x 5-min | AWS CDK `BedrockLatencyAlarm` |
| `openclaw-pod-coldstart-slow` | `OpenClaw/ColdStart/PodStartupDurationSeconds` | Max > 60s in 5 min | AWS CDK `ColdStartAlarm` |

## Usage Tracking

All tenants share a single IAM Role. Amazon Bedrock CloudWatch metrics cannot distinguish tenants at the IAM level.

Solution: OpenClaw gateway logs each Amazon Bedrock invocation with token counts. Container Insights collects pod stdout tagged with Kubernetes namespace (1:1 mapping to tenants).

```
OpenClaw Pod (stdout) -> Container Insights -> CloudWatch Logs
                                                -> Metric Filter (OpenClaw/Usage)
                                                -> Dashboard + Logs Insights queries
```

### Metric Filters

| Filter | Pattern | Metric |
|---|---|---|
| `openclaw-input-tokens` | `{ $.input_tokens = * }` | `OpenClaw/Usage/BedrockInputTokens` |
| `openclaw-output-tokens` | `{ $.output_tokens = * }` | `OpenClaw/Usage/BedrockOutputTokens` |

## Cost Enforcer AWS Lambda

`cdk/lambda/cost-enforcer/index.py` -- runs daily via EventBridge.

1. Queries CloudWatch Logs Insights for per-namespace token usage
2. Applies per-model pricing (Opus $15/$75, Sonnet $3/$15, DeepSeek $0.14/$0.28 per 1M tokens)
3. Reads budget from SM tag (`budget-usd`)
4. SNS alerts at 80% and 100% thresholds

## Operational Scripts

| Script | Purpose |
|---|---|
| `health-check.sh` | JSON health report (KEDA, PVCs, ALB, Amazon CloudFront, AWS WAF) |
| `usage-report.sh --month YYYY-MM` | Monthly per-tenant cost report |
| AWS CDK metric filters | Metric filters + dashboard |
| AWS CDK `BedrockLatencyAlarm` | Amazon Bedrock P95 latency alarm |
| AWS CDK `ColdStartAlarm` | Cold start alarm |

## Cost

- CloudWatch Logs Insights: first 5 GB scanned free, then $0.005/GB
- Metric Filters: free
- Dashboard: $3/month
- Cost Enforcer AWS Lambda: negligible
