# User Journey

## Overview

A company employee goes from zero to chatting with their personal AI assistant in under 5 minutes.

## Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. Open https://your-domain.com                                │
│     → CloudFront #1 → S3 → Custom auth UI                      │
│                                                                 │
│  2. Sign Up (email + password + CAPTCHA)                        │
│     → Cognito SDK → Pre-signup Lambda (domain check)            │
│                                                                 │
│  3. Verify email (enter code from inbox)                        │
│     → Cognito ConfirmSignUp                                     │
│                                                                 │
│  4. "Account Created — being set up"                  │
│     → Admin receives SNS notification                           │
│                                                                 │
│  5. Email verified in Cognito Console                           │
│     → Post-confirmation Lambda:                                 │
│       a. Secrets Manager secret                                 │
│       b. Pod Identity Association                               │
│       c. CodeBuild → helm install                               │
│       d. SES welcome email to user                              │
│                                                                 │
│  6. User receives email: "Your URL is alice.your-domain.com"    │
│                                                                 │
│  7. Open https://alice.your-domain.com                          │
│     → CloudFront #2 → VPC Origin → Internal ALB                │
│     → Cognito auth → OpenClaw Control UI                        │
│                                                                 │
│  8. Chat with AI assistant (Bedrock, zero API keys)             │
│                                                                 │
│  9. Idle 15 min → KEDA scales pod to 0 (data preserved)        │
│                                                                 │
│  10. Return later → "Waking up..." (15-30s) → resume            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Step Details

### 1. Landing Page

- URL: `https://your-domain.com`
- Served by CloudFront #1 → S3 bucket
- Custom auth UI with AI-Native purple theme (#6366F1)
- Tabbed interface: Sign In / Sign Up

### 2. Sign Up

- Email must match allowed domain (configured in Pre-signup Lambda)
- Password: min 12 characters, uppercase, lowercase, numbers
- Visual password strength meter (red → orange → green)
- Cloudflare Turnstile CAPTCHA (optional, enabled via env var)
- Cognito SDK `SignUp` API call (no redirect to Cognito Hosted UI)

### 3. Email Verification

- Cognito sends 6-digit code to user's email
- User enters code on the verify screen
- "Resend code" link available if email is delayed

### 4. Pending Approval

- User sees "Account Created — being set up" page
- Admin receives SNS email notification
- User cannot log in until admin approves

### 5. Admin Approval

- Admin confirms user in AWS Cognito Console
- Post-confirmation Lambda triggers automatically (see [Admin Journey](admin-journey.md))

### 6. Welcome Email

- Sent via Amazon SES directly to user's email
- Contains tenant URL: `https://<name>.your-domain.com`
- Sent within seconds of auto-provisioning

### 7. First Login

- User opens their tenant URL
- CloudFront #2 → VPC Origin → Internal ALB
- ALB Cognito auth action redirects to Cognito login
- User enters email + password
- ALB validates token, sets 7-day session cookie
- Forwarded to OpenClaw Control UI

### 8. Daily Usage

- Chat with AI assistant powered by Amazon Bedrock
- Available models: Opus 4.6, Sonnet 4.6, DeepSeek V3.2, GPT-OSS 120B, Qwen3 Coder, Kimi K2
- Skills: configurable per tenant (default: weather, gog)
- Session persists for 7 days (ALB auth session timeout)

### 9. Scale to Zero

- After 15 minutes of no HTTP requests, KEDA scales pod to 0
- PVC (EBS volume) is NOT deleted — all data preserved
- No cost for idle tenants (EC2 only charges for running pods)

### 10. Cold Start

- User opens URL → CloudFront forwards to ALB → ALB returns 502/503
- CloudFront custom error response shows branded loading page
- Page auto-refreshes every 5 seconds
- Pod starts in 15-30 seconds → next refresh loads OpenClaw

### Forgot Password

- Click "Forgot password?" on login page
- Enter email → receive reset code
- Enter code + new password → password reset
- Redirect to login

## What the User Never Sees

- AWS Cognito Hosted UI (all auth via custom UI + Cognito SDK)
- Internal ALB (hidden behind CloudFront)
- EKS, pods, namespaces (abstracted away)
- API keys (Bedrock via Pod Identity)
