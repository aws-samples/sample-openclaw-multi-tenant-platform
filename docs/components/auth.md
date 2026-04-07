# Authentication & Signup

## Overview

Cognito User Pool for identity, custom auth UI (no Hosted UI). Gateway runs in token auth mode with exec SecretRef -> Secrets Manager. Signup auto-provisions tenant infrastructure via Lambda triggers and the ApplicationSet.

## Architecture

```
User -> Custom Auth UI (auth-ui/index.html)
         |
         +- Sign Up -> Cognito SignUp API
         |              -> Pre-Signup Lambda (domain check + CAPTCHA)
         |              -> Post-Confirmation Lambda:
         |                 a. Secrets Manager secret (gateway token)
         |                 b. Pod Identity Association
         |                 c. ApplicationSet element -> ArgoCD -> Helm -> pod ready (~2 min)
         |
         +- Sign In -> Cognito InitiateAuth (USER_PASSWORD_AUTH)
                        -> Redirect to https://claw.{domain}/t/{tenant}/
                        -> CloudFront -> Internet-facing ALB (CF prefix list SG)
                        -> Gateway API HTTPRoute -> OpenClaw gateway (token auth)
```

## Custom Auth UI

**Location:** `auth-ui/index.html`

Single-page app that talks directly to Cognito API via raw `fetch()`. No SDK dependency.

Why not Cognito Hosted UI: ugly URLs, limited customization.

Features: sign in/up tabs, forgot password, password strength indicator.

## Pre-Signup Lambda

**Location:** `cdk/lambda/pre-signup/index.py`

- Email domain restriction (`ALLOWED_DOMAINS`)
- AWS WAF Bot Control (opt-in, server-side)
- `autoConfirmUser = true`, `autoVerifyEmail = true`
- SNS notify admin

## Post-Confirmation Lambda

**Location:** `cdk/lambda/post-confirmation/index.py`

1. Create Secrets Manager secret: `openclaw/{tenant}/gateway-token` (tagged for ABAC)
2. Create EKS Pod Identity Association (namespace `openclaw-{tenant}`, SA `{tenant}`)
3. Create ApplicationSet element -> ApplicationSet generates Applications (NS, PVC, SA, ArgoCD App, KEDA HSO)

## Gateway Auth Mode

The gateway runs in `token` auth mode. Authentication is handled by the gateway itself using a token fetched on-demand from Secrets Manager via exec SecretRef. No ALB Cognito auth.

Security is provided by the internet-facing ALB with CloudFront prefix list SG restriction (`pl-82a045eb`) -- only CloudFront IPs can reach the ALB.

From `values.yaml`:

```yaml
config:
  gateway:
    auth:
      mode: token
      token:
        source: exec
        provider: aws-sm
        id: gateway-token
```

### Path-Based Routing

HTTPRoute routes `claw.{domain}/t/{tenant}/` to the tenant service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  parentRefs:
    - name: openclaw-gateway
      namespace: openclaw-system
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /t/{tenant}
      backendRefs:
        - name: {tenant}
          port: 18789
```

## Session

- Scope: per-sender
- Reset mode: idle
- Idle timeout: 60 minutes
- No ALB session cookies -- session is managed by the gateway

## Tenant Name Derivation

Email -> tenant name mapping (consistent across all components):

```
user.name+tag@example.com -> usernamtag (max 20 chars, [a-z0-9-] only)
```

## Security

- Public client -- no client secret (safe for browser SPA)
- Email domain restriction -- pre-signup Lambda rejects non-allowed domains
- Bot protection -- AWS WAF Bot Control (opt-in via CDK context)
- Gateway token -- `secrets.token_urlsafe(32)`, stored in SM with ABAC tags
- Password policy -- min 12 chars, uppercase + lowercase + numbers
