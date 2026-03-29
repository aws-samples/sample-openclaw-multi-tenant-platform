# Authentication & Signup

## Overview

OpenClaw uses Amazon Cognito User Pool for identity, a custom auth UI (no Hosted UI), and ALB Cognito auth action for tenant ingress. The signup flow auto-provisions tenant infrastructure via Lambda triggers.

## Architecture

```
User → Custom Auth UI (auth-ui/index.html)
         │
         ├─ Sign Up → Cognito SignUp API
         │              ↓
         │         Pre-Signup Lambda
         │         ├─ Email domain restriction (ALLOWED_DOMAINS)
         │         ├─ Cloudflare Turnstile CAPTCHA verification
         │         ├─ autoConfirmUser = false
         │         ├─ autoVerifyEmail = true
         │         └─ SNS notify admin
         │              ↓
         │         User enters verification code → ConfirmSignUp
         │              ↓
         │         Admin confirms user in Cognito Console
         │              ↓
         │         Post-Confirmation Lambda
         │         ├─ Create Secrets Manager secret (gateway token)
         │         ├─ Create EKS Pod Identity Association
         │         ├─ Trigger CodeBuild (helm install)
         │         ├─ SNS notify admin
         │         └─ SES welcome email to user
         │              ↓
         │         CodeBuild runs helm install → tenant pod ready (~2 min)
         │
         └─ Sign In → Cognito InitiateAuth (USER_PASSWORD_AUTH)
                        ↓
                   Redirect to https://{tenant}.{domain}
                        ↓
                   ALB Cognito auth action (trusted-proxy mode)
                        ↓
                   OpenClaw gateway reads x-amzn-oidc-identity header
```

## Custom Auth UI

**Location:** `auth-ui/index.html`

A single-page app that talks directly to the Cognito API via `AWSCognitoIdentityProviderService` JSON RPC. No SDK dependency — raw `fetch()` calls.

**Why not Cognito Hosted UI:**
- Hosted UI URLs are ugly (`https://{domain}.auth.{region}.amazoncognito.com/...`)
- Limited CSS customization, no control over layout or UX flow
- Can't integrate Cloudflare Turnstile CAPTCHA
- Can't show custom post-signup messages (e.g., "being set up")

**Features:**
- Sign in / Sign up tabs
- Email verification code flow
- Forgot password / reset flow
- Cloudflare Turnstile CAPTCHA on signup
- Password strength indicator
- Friendly error message mapping
- Remembers last email in localStorage

**Cognito config (injected at deploy):**

```javascript
const C = {
  region: 'us-west-2',
  userPoolId: '',      // injected
  clientId: '',        // injected — public client, no secret
  domain: '',          // e.g. openclaw.example.com
  turnstileSiteKey: '' // Cloudflare Turnstile
};
```

**Auth flow:** `USER_PASSWORD_AUTH` (public client, no client secret). After successful sign-in, the UI derives the tenant subdomain from the email local part and redirects:

```javascript
const tenant = email.split('@')[0].toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 20);
window.location.href = `https://${tenant}.${C.domain}`;
```

## Pre-Signup Lambda

**Location:** `cdk/lambda/pre-signup/index.py`

Cognito Pre Sign-up trigger. Runs before the user is created.

```python
ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', '').split(',')]
TURNSTILE_SECRET = os.environ.get('TURNSTILE_SECRET', '')

def handler(event, context):
    email = event['request']['userAttributes'].get('email', 'unknown')
    domain = email.split('@')[-1].lower()

    # 1. Email domain restriction
    if domain not in ALLOWED_DOMAINS:
        raise Exception(f'Email domain not allowed: {domain}')

    # 2. Turnstile CAPTCHA verification (if configured)
    if TURNSTILE_SECRET:
        token = event['request'].get('clientMetadata', {}).get('turnstileToken', '')
        if not token:
            raise Exception('CAPTCHA token missing')
        verify_turnstile(token)  # POST to Cloudflare siteverify API

    # 3. Require auto-provisioning
    event['response']['autoConfirmUser'] = False
    event['response']['autoVerifyEmail'] = True

    # 4. Notify admin
    sns.publish(TopicArn=TOPIC_ARN, Subject='New User Signup', Message=f'New signup: {email}')
    return event
```

**Environment variables:** `ALLOWED_DOMAINS`, `TURNSTILE_SECRET`, `SNS_TOPIC_ARN`

## Post-Confirmation Lambda

**Location:** `cdk/lambda/post-confirmation/index.py`

Cognito Post Confirmation trigger. Runs after admin confirms the user. Provisions all tenant infrastructure:

```python
def handler(event, context):
    email = event['request']['userAttributes']['email']
    tenant = re.sub(r'[^a-z0-9-]', '', email.split('@')[0].lower())[:20].strip('-')
    ns = f'openclaw-{tenant}'

    # 1. Gateway token in Secrets Manager (tagged for ABAC)
    sm.create_secret(
        Name=f'openclaw/{tenant}/gateway-token',
        SecretString=secrets.token_urlsafe(32),
        Tags=[{'Key': 'tenant-namespace', 'Value': ns}],
    )

    # 2. EKS Pod Identity Association
    eks_client.create_pod_identity_association(
        clusterName=CLUSTER_NAME, namespace=ns,
        serviceAccount=f'openclaw-{tenant}', roleArn=TENANT_ROLE_ARN,
    )

    # 3. Trigger CodeBuild to helm install
    cb.start_build(
        projectName=CODEBUILD_PROJECT,
        environmentVariablesOverride=[
            {'name': 'TENANT_NAME', 'value': tenant, 'type': 'PLAINTEXT'},
        ],
    )

    # 4. SNS notify admin
    # 5. SES welcome email to user with tenant URL
```

**Environment variables:** `SNS_TOPIC_ARN`, `CLUSTER_NAME`, `TENANT_ROLE_ARN`, `DOMAIN`, `CODEBUILD_PROJECT`, `SES_FROM_EMAIL`

**IAM permissions:** `secretsmanager:CreateSecret`, `eks:CreatePodIdentityAssociation`, `codebuild:StartBuild`, `sns:Publish`, `ses:SendEmail`

## ALB Cognito Auth Action

Each tenant ingress has ALB-native Cognito authentication. Configured in `helm/charts/openclaw-platform/templates/ingress.yaml`:

```yaml
# When ingress.cognito.enabled = true:
alb.ingress.kubernetes.io/auth-type: cognito
alb.ingress.kubernetes.io/auth-idp-cognito: |
  {"userPoolARN":"...","userPoolClientID":"...","userPoolDomain":"..."}
alb.ingress.kubernetes.io/auth-scope: openid email profile
alb.ingress.kubernetes.io/auth-on-unauthenticated-request: authenticate
alb.ingress.kubernetes.io/auth-session-timeout: "604800"  # 7 days
```

The OpenClaw gateway runs in `trusted-proxy` mode — it reads the authenticated user identity from ALB-injected headers:

```yaml
# values.yaml
config:
  gateway:
    auth:
      mode: trusted-proxy
      trustedProxy:
        userHeader: x-amzn-oidc-identity
        requiredHeaders:
          - x-amzn-oidc-data
    trustedProxies:
      - "10.0.0.0/8"  # VPC CIDR
```

## Tenant Name Derivation

Email → tenant name mapping is consistent across all components:

```
user.name+tag@example.com → username+tag → usernamtag (max 20 chars, [a-z0-9-] only)
```

The same regex `re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')` is used in both the post-confirmation Lambda and the auth UI redirect.

## Security

- **Public client** — no client secret (safe for browser-based SPA)
- **Email domain restriction** — pre-signup Lambda rejects non-allowed domains
- **CAPTCHA** — Cloudflare Turnstile on signup (server-side verification)
- **Admin approval** — `autoConfirmUser = false`, admin must confirm in Cognito Console
- **Gateway token** — `secrets.token_urlsafe(32)`, stored in Secrets Manager with ABAC tags
- **Tenant isolation** — Pod Identity scoped per namespace, Secrets Manager access via ABAC
- **Password policy** — min 12 chars, uppercase + lowercase + numbers (enforced by Cognito + UI)

## CDK Resources

| Resource | Purpose |
|----------|---------|
| `PreSignupFn` | Lambda + IAM role (sns:Publish) |
| `PostConfirmFn` | Lambda + IAM role (secretsmanager, eks, codebuild, sns, ses) |
| `TenantBuilder` | CodeBuild project + IAM role (eks:DescribeCluster) |

Cognito triggers are attached via `scripts/setup-signup-triggers.sh` (User Pool is imported, not CDK-managed).
