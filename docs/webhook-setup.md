# Webhook 設定指南

## 架構

CloudFront #2 已將 `*.your-domain.com` 路由到 internal ALB，所有 tenant subdomain 的 `/webhook/*` path 自動通過 ALB → Ingress → tenant pod，不需額外設定 DNS 或 Ingress rule。

```
Slack/Discord → https://alice.your-domain.com/webhook/slack
                        ↓
                  CloudFront #2 (*.domain)
                        ↓
                  Internal ALB → tenant pod
```

## Slack Webhook 設定

1. 到 [Slack API](https://api.slack.com/apps) 建立 App
2. 啟用 **Incoming Webhooks** 或 **Event Subscriptions**
3. Event Subscriptions Request URL 填：
   ```
   https://alice.your-domain.com/webhook/slack
   ```
4. 在 OpenClaw config 加入 webhook channel：

```json
{
  "integrations": {
    "slack": {
      "webhookPath": "/webhook/slack",
      "channel": "#notifications",
      "signingSecret": "<from-slack-app-settings>"
    }
  }
}
```

## Discord Webhook 設定

1. Discord Server Settings → Integrations → Webhooks → New Webhook
2. 複製 Webhook URL（用於 outgoing）
3. 在 OpenClaw config 加入：

```json
{
  "integrations": {
    "discord": {
      "webhookPath": "/webhook/discord",
      "outgoingUrl": "https://discord.com/api/webhooks/<id>/<token>"
    }
  }
}
```

## Helm values 設定

在 tenant values 裡啟用 webhook：

```yaml
config:
  integrations:
    slack:
      webhookPath: /webhook/slack
      channel: "#notifications"
    discord:
      webhookPath: /webhook/discord
```

## 驗證

```bash
# 測試 webhook endpoint 是否可達
curl -s -o /dev/null -w "%{http_code}" https://alice.your-domain.com/webhook/slack
```
