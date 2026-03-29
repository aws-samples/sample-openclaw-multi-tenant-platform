# Webhook Setup Guide

## Architecture

CloudFront #2 routes `*.your-domain.com` to the internal ALB. All tenant subdomain `/webhook/*` paths automatically go through ALB → Ingress → tenant pod — no extra DNS or Ingress rule needed.

```
Slack/Discord → https://alice.your-domain.com/webhook/slack
                        ↓
                  CloudFront #2 (*.domain)
                        ↓
                  Internal ALB → tenant pod
```

## Slack Webhook Setup

1. Go to [Slack API](https://api.slack.com/apps) and create an App
2. Enable **Incoming Webhooks** or **Event Subscriptions**
3. Set the Event Subscriptions Request URL to:
   ```
   https://alice.your-domain.com/webhook/slack
   ```
4. Add the webhook channel in OpenClaw config:

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

## Discord Webhook Setup

1. Discord Server Settings → Integrations → Webhooks → New Webhook
2. Copy the Webhook URL (for outgoing)
3. Add to OpenClaw config:

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

## Helm Values Configuration

Enable webhooks in tenant values:

```yaml
config:
  integrations:
    slack:
      webhookPath: /webhook/slack
      channel: "#notifications"
    discord:
      webhookPath: /webhook/discord
```

## Verification

```bash
# Test whether the webhook endpoint is reachable
curl -s -o /dev/null -w "%{http_code}" https://alice.your-domain.com/webhook/slack
```
