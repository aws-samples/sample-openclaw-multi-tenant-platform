# Webhook Setup Guide

## Architecture

CloudFront routes `claw.your-domain.com/t/{tenant}/webhook/*` through the internet-facing ALB (CF prefix list SG) -> Gateway API HTTPRoute -> tenant pod. No extra DNS or routing needed.

```
Slack/Discord -> https://claw.your-domain.com/t/alice/webhook/slack
                        |
                  CloudFront
                        |
                  Internet-facing ALB (CF prefix list SG) -> tenant pod
```

## Slack Webhook Setup

1. Go to [Slack API](https://api.slack.com/apps) and create an App
2. Enable **Event Subscriptions**
3. Set the Request URL to:
   ```
   https://claw.your-domain.com/t/alice/webhook/slack
   ```
4. Add webhook config in OpenClaw config

## Discord Webhook Setup

1. Discord Server Settings -> Integrations -> Webhooks -> New Webhook
2. Copy the Webhook URL (for outgoing)
3. Add to OpenClaw config

## Helm Values Configuration

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
curl -s -o /dev/null -w "%{http_code}" https://claw.your-domain.com/t/alice/webhook/slack
```
