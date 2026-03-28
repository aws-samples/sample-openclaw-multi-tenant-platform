# Per-Tenant Usage Tracking 與成本分攤

## 目標

追蹤每個 tenant 的 Bedrock token 用量，產出月度成本分攤報表。

## 挑戰

所有 tenant 共用同一個 IAM Role（`OpenClawTenantRole`），Bedrock CloudWatch metrics 無法直接區分 tenant。

## 方案比較

| 方案 | 做法 | 優點 | 缺點 |
|------|------|------|------|
| **A: OpenClaw Log Parsing** | 從 gateway log 擷取 token usage | 零額外成本；Container Insights 已收集 log | 依賴 log 格式穩定 |
| **B: CloudTrail + Athena** | Bedrock API calls 在 CloudTrail，用 Athena 查詢 | 精確；AWS 原生 | 設定複雜；Athena 有查詢成本 |

## 推薦方案 A：OpenClaw Log Parsing

### 原理

OpenClaw gateway 每次 Bedrock 呼叫會 log：
- Model ID
- Input / Output token count
- Duration

Container Insights 會把 pod stdout 送到 CloudWatch Logs，log group 格式：
```
/aws/containerinsights/openclaw-cluster/application
```

每筆 log 帶有 kubernetes namespace label，可用來區分 tenant。

### CloudWatch Logs Insights 查詢

```
# 每個 tenant 的月度 token 用量
fields @timestamp, kubernetes.namespace_name as tenant, @message
| filter @message like /tokens/
| parse @message '"input_tokens":*,' as input_tokens
| parse @message '"output_tokens":*,' as output_tokens
| stats sum(input_tokens) as total_input, sum(output_tokens) as total_output by tenant
```

### Metric Filter

在 CloudWatch Logs 建立 Metric Filter，擷取 per-namespace token usage：

```json
{
  "filterPattern": "{ $.input_tokens = * }",
  "metricTransformations": [
    {
      "metricName": "BedrockInputTokens",
      "metricNamespace": "OpenClaw/Usage",
      "metricValue": "$.input_tokens",
      "dimensions": {
        "Tenant": "$.kubernetes.namespace_name"
      }
    }
  ]
}
```

### 成本分攤公式

Bedrock 定價（以 Sonnet 4.6 為例）：
- Input: $3.00 / 1M tokens
- Output: $15.00 / 1M tokens

```
tenant_monthly_cost = (input_tokens / 1_000_000 * input_price)
                    + (output_tokens / 1_000_000 * output_price)
```

### Dashboard JSON 範例

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "title": "Input Tokens by Tenant",
        "metrics": [
          ["OpenClaw/Usage", "BedrockInputTokens", "Tenant", "openclaw-alice"],
          ["OpenClaw/Usage", "BedrockInputTokens", "Tenant", "openclaw-bob"],
          ["OpenClaw/Usage", "BedrockInputTokens", "Tenant", "openclaw-carol"]
        ],
        "period": 86400,
        "stat": "Sum",
        "region": "us-west-2"
      }
    }
  ]
}
```

### 實作步驟

1. 確認 Container Insights log group 存在：
   ```bash
   aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/openclaw-cluster
   ```

2. 確認 OpenClaw log 格式含 token count：
   ```bash
   kubectl logs -n openclaw-alice deploy/openclaw-alice | grep tokens | head -5
   ```

3. 建立 Metric Filter：
   ```bash
   aws logs put-metric-filter \
     --log-group-name /aws/containerinsights/openclaw-cluster/application \
     --filter-name openclaw-token-usage \
     --filter-pattern '{ $.input_tokens = * }' \
     --metric-transformations \
       metricName=BedrockInputTokens,metricNamespace=OpenClaw/Usage,metricValue='$.input_tokens'
   ```

4. 建立 CloudWatch Dashboard：
   ```bash
   aws cloudwatch put-dashboard \
     --dashboard-name OpenClaw-Usage \
     --dashboard-body file://scripts/usage-dashboard.json
   ```

5. 月底跑 Logs Insights 查詢產出分攤報表

## 注意事項

- OpenClaw log 格式可能隨版本變動，升版後需驗證 Metric Filter 仍有效
- 多 model 場景需要分別計價（Opus vs Sonnet vs DeepSeek 價格不同）
- 免費層：CloudWatch Logs Insights 前 5GB 掃描免費，之後 $0.005/GB
