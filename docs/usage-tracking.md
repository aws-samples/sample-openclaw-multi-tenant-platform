# Per-Tenant Usage Tracking and Cost Allocation

## Goal

Track Bedrock token usage per tenant and produce monthly cost allocation reports.

## Challenge

All tenants share a single IAM Role (`OpenClawTenantRole`). Bedrock CloudWatch metrics cannot distinguish between tenants at the IAM level.

## Solution: OpenClaw Log Parsing

OpenClaw gateway logs each Bedrock invocation with token counts. Container Insights collects pod stdout to CloudWatch Logs, tagged with the Kubernetes namespace (which maps 1:1 to tenants).

### Data Flow

```
OpenClaw Pod (stdout) → Container Insights → CloudWatch Logs
                                               ↓
                                         Metric Filter
                                         (extract input_tokens, output_tokens per namespace)
                                               ↓
                                         CloudWatch Metrics (OpenClaw/Usage)
                                               ↓
                                         Dashboard + Logs Insights query
```

### CloudWatch Logs Insights Query

```sql
fields @timestamp, kubernetes.namespace_name as tenant, @message
| filter @message like /tokens/
| parse @message '"input_tokens":*,' as input_tokens
| parse @message '"output_tokens":*,' as output_tokens
| stats sum(input_tokens) as total_input, sum(output_tokens) as total_output by tenant
```

### Cost Allocation Formula

Using Sonnet 4.6 pricing as reference:
- Input: $3.00 / 1M tokens
- Output: $15.00 / 1M tokens

```
tenant_monthly_cost = (input_tokens / 1,000,000 × input_price)
                    + (output_tokens / 1,000,000 × output_price)
```

For multi-model usage, apply each model's pricing separately.

## Setup

```bash
# Create metric filters + CloudWatch dashboard
./scripts/setup-usage-tracking.sh

# Generate monthly cost report
./scripts/usage-report.sh --month 2026-03
```

### What `setup-usage-tracking.sh` Does

1. Creates CloudWatch Metric Filter on Container Insights log group
2. Creates `OpenClaw-Usage` dashboard with per-tenant token widgets

### What `usage-report.sh` Does

1. Runs Logs Insights query for the specified month
2. Outputs a table: `TENANT | INPUT_TOKENS | OUTPUT_TOKENS | EST_COST`

## Cost

- CloudWatch Logs Insights: first 5GB scanned free, then $0.005/GB
- Metric Filters: free
- Dashboard: $3/month per dashboard

## Notes

- OpenClaw log format may change between versions — verify metric filter after upgrades
- Multi-model scenarios require per-model pricing (Opus vs Sonnet vs DeepSeek have different rates)
- Dashboard shows daily aggregates; use `usage-report.sh` for monthly totals
