# User Journey

## Flow

```
1. Open https://your-domain.com
   -> CloudFront #1 -> S3 -> Custom auth UI

2. Sign Up (email + password + CAPTCHA)
   -> Cognito SDK -> Pre-signup Lambda (domain check)

3. "Account Created -- being set up"
   -> Post-confirmation Lambda:
     a. Secrets Manager secret
     b. Pod Identity Association
     c. ApplicationSet element -> ArgoCD -> Helm -> pod ready (~2 min)
     d. SES welcome email

4. User receives email: "Your URL is claw.your-domain.com/t/alice/"

5. Open https://claw.your-domain.com/t/alice/
   -> CloudFront -> Internet-facing ALB (CF prefix list SG)
   -> Gateway API HTTPRoute -> OpenClaw gateway (token auth)

6. Chat with AI assistant (Bedrock, zero API keys)

7. Idle 15 min -> KEDA scales pod to 0 (data preserved on PVC)

8. Return later -> "Waking up..." (15-30s) -> resume
```

## Step Details

### Landing Page

- URL: `https://your-domain.com`
- CloudFront #1 -> S3 bucket
- Custom auth UI with tabbed Sign In / Sign Up

### Sign Up

- Email must match allowed domain
- Password: min 12 chars, uppercase, lowercase, numbers
- AWS WAF Bot Control (optional, enable via CDK context)
- Cognito SDK `SignUp` API call (no Hosted UI redirect)

### Workspace Provisioning

- Post-confirmation Lambda creates ApplicationSet element
- ApplicationSet + ArgoCD provisions Namespace, PVC, ServiceAccount, Deployment, KEDA HSO
- ArgoCD syncs Helm chart -> Deployment, Service, ConfigMap, NetworkPolicy, etc.
- User receives welcome email with workspace URL

### First Login

- User opens their tenant URL (`claw.{domain}/t/{tenant}/`)
- CloudFront -> internet-facing ALB (CF prefix list SG) -> Gateway API HTTPRoute
- OpenClaw gateway handles auth locally (token mode via exec SecretRef -> Secrets Manager)

### Daily Usage

- Chat with AI assistant powered by Amazon Bedrock
- Session persists until 60 minutes idle, then resets
- No ALB session cookies -- session managed by gateway

### Scale to Zero

- After 15 minutes of no HTTP requests, KEDA scales pod to 0
- PVC (EFS) is NOT deleted -- all data preserved
- No cost for idle tenants

### Cold Start

- User opens URL -> KEDA interceptor holds request -> pod starts (15-30s)
- Custom 503 page with auto-refresh every 5 seconds during cold start

### Forgot Password

- Click "Forgot password?" -> receive reset code -> enter code + new password

## What the User Never Sees

- AWS Cognito Hosted UI (all auth via custom UI + Cognito SDK)
- ALB, EKS, pods, namespaces (abstracted away)
- API keys (Bedrock via Pod Identity)
