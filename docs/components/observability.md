# Observability — Monitoring, Alerting, and Cost Tracking

## CloudWatch Container Insights

Deployed as an EKS addon (`amazon-cloudwatch-observability`) via CDK. Uses Pod Identity with a role that has `CloudWatchAgentServerPolicy` and `AWSXrayWriteOnlyAccess`.

Container Insights collects pod stdout to CloudWatch Logs, which is the foundation for all usage tracking and custom metrics.

Log groups:
- `/aws/containerinsights/openclaw-cluster/application` — application logs (token usage)
- `/aws/containerinsights/openclaw-cluster/performance` — pod lifecycle metrics (cold start)

## CloudWatch Alarms

All alarms publish to the `OpenClawAlerts` SNS topic (created by CDK).

| Alarm | Metric | Condition | Setup |
|---|---|---|---|
| `OpenClaw-PodRestartCount` | `ContainerInsights/pod_number_of_container_restarts` | Sum > 0 in 5 min | CDK (automatic) |
| `openclaw-bedrock-p95-latency` | `OpenClaw/Bedrock/BedrockResponseTimeMs` | P95 > 10s for 2× 5-min periods | `setup-bedrock-latency.sh` |
| `openclaw-pod-coldstart-slow` | `OpenClaw/ColdStart/PodStartupDurationSeconds` | Max > 60s in 5 min | `setup-coldstart-alarm.sh` |

### Bedrock Latency Alarm

A metric filter extracts response time from Container Insights application logs and pushes to `OpenClaw/Bedrock/BedrockResponseTimeMs`:

```bash
# Filter pattern
{ $.message = "*bedrock*response*" && $.duration = * }
```

### Cold Start Alarm

A metric filter on the performance log group extracts `pod_startup_duration_seconds`:

```bash
# Filter pattern
{ $.Type = "Pod" && $.PodStatus = "Running" && $.pod_startup_duration_seconds = * }
```

## SNS Alerts Topic

The `OpenClawAlerts` SNS topic is the central alert bus. Publishers:
- CloudWatch Alarms (pod restart, latency, cold start)
- Cost Enforcer Lambda (budget alerts)
- Pre-Signup Lambda (new user notifications)

## Usage Tracking

### Challenge

All tenants share a single IAM Role. Bedrock CloudWatch metrics cannot distinguish tenants at the IAM level.

### Solution

OpenClaw gateway logs each Bedrock invocation with token counts. Container Insights collects pod stdout tagged with the Kubernetes namespace (1:1 mapping to tenants).

```
OpenClaw Pod (stdout) → Container Insights → CloudWatch Logs
                                               ↓
                                         Metric Filter (OpenClaw/Usage)
                                               ↓
                                         Dashboard + Logs Insights queries
```

### Metric Filters

Created by `setup-usage-tracking.sh`:

| Filter | Pattern | Metric |
|---|---|---|
| `openclaw-input-tokens` | `{ $.input_tokens = * }` | `OpenClaw/Usage/BedrockInputTokens` |
| `openclaw-output-tokens` | `{ $.output_tokens = * }` | `OpenClaw/Usage/BedrockOutputTokens` |

### CloudWatch Dashboard

`OpenClaw-Usage` dashboard shows daily input/output token aggregates per tenant. Created by `setup-usage-tracking.sh`.

### Logs Insights Query

```sql
fields @timestamp, kubernetes.namespace_name as tenant, @message
| filter @message like /tokens/
| parse @message '"input_tokens":*,' as input_tokens
| parse @message '"output_tokens":*,' as output_tokens
| stats sum(input_tokens) as total_input, sum(output_tokens) as total_output by tenant
```

## Cost Enforcer Lambda

`cdk/lambda/cost-enforcer/index.py` — runs daily via EventBridge, queries CloudWatch Logs Insights for per-namespace token usage this month.

### How It Works

1. Runs a Logs Insights query against Container Insights application logs
2. Aggregates input/output tokens per namespace, applies per-model pricing
3. Reads each tenant's budget from Secrets Manager tag (`budget-usd` on `openclaw/<tenant>/gateway-token`)
4. Sends SNS alerts at 80% and 100% budget thresholds

### Pricing Table

| Model | Input ($/1M tokens) | Output ($/1M tokens) |
|---|---|---|
| `anthropic.claude-opus-4` | $15.00 | $75.00 |
| `anthropic.claude-sonnet-4` | $3.00 | $15.00 |
| `deepseek` | $0.14 | $0.28 |
| default | $3.00 | $15.00 |

### Cost Formula

```
tenant_cost = Σ (input_tokens × model_input_price + output_tokens × model_output_price) / 1,000,000
```

## Operational Scripts

### `health-check.sh`

Outputs a JSON health report checking:
- KEDA pods running in `keda` namespace
- PVCs bound for openclaw-helm workloads
- ALB health via ingress endpoint `/healthz`
- CloudFront distribution status
- WAF web ACL presence

```bash
./scripts/health-check.sh
# {"status": "healthy", "components": {"keda": "ok", "pvc": "ok", ...}}
```

### `usage-report.sh`

Monthly cost report from Logs Insights. Outputs a table of tenant / input tokens / output tokens / estimated cost.

```bash
./scripts/usage-report.sh --month 2026-03 --region us-west-2
```

Uses Sonnet pricing ($3/1M input, $15/1M output) by default.

## Setup Commands

```bash
./scripts/setup-usage-tracking.sh      # Metric filters + dashboard
./scripts/setup-bedrock-latency.sh     # Bedrock P95 latency alarm
./scripts/setup-coldstart-alarm.sh     # Cold start alarm
```

## Cost

- CloudWatch Logs Insights: first 5 GB scanned free, then $0.005/GB
- Metric Filters: free
- Dashboard: $3/month
- Cost Enforcer Lambda: negligible (daily invocation, ~256 MB, <5 min)

## Files

| File | Purpose |
|---|---|
| `cdk/lambda/cost-enforcer/index.py` | Daily cost enforcement Lambda |
| `scripts/setup-usage-tracking.sh` | Metric filters + usage dashboard |
| `scripts/setup-bedrock-latency.sh` | Bedrock P95 latency alarm |
| `scripts/setup-coldstart-alarm.sh` | Cold start alarm |
| `scripts/health-check.sh` | Platform health JSON |
| `scripts/usage-report.sh` | Monthly cost report |
