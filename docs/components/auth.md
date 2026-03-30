# Authentication & Signup

## Overview

OpenClaw uses Amazon Cognito User Pool for identity and a custom auth UI (no Hosted UI). The gateway runs in local auth mode (security via CloudFront + internal ALB). The signup flow auto-provisions tenant infrastructure via Lambda triggers and the Tenant Operator.

## Architecture

```
User → Custom Auth UI (auth-ui/index.html)
         │
         ├─ Sign Up → Cognito SignUp API
         │              ↓
         │         Pre-Signup Lambda
         │         ├─ Email domain restriction (ALLOWED_DOMAINS)
         │         ├─ Cloudflare Turnstile CAPTCHA verification
         │         ├─ autoConfirmUser = true
         │         ├─ autoVerifyEmail = true
         │         └─ SNS notify admin
         │              ↓
         │         Post-Confirmation Lambda
         │         ├─ Create Secrets Manager secret (gateway token)
         │         ├─ Create EKS Pod Identity Association
         │         ├─ Create Tenant CR (operator reconciles)
         │         ├─ SNS notify admin
         │         └─ SES welcome email to user
         │              ↓
         │         Operator → ArgoCD → tenant pod ready (~2 min)
         │
         └─ Sign In → Cognito InitiateAuth (USER_PASSWORD_AUTH)
                        ↓
                   Redirect to https://claw.{domain}/t/{tenant}/
                        ↓
                   CloudFront → Internal ALB → Gateway API HTTPRoute
                        ↓
                   OpenClaw gateway (local auth mode)
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

    # 3. Auto-confirm (no email verification, no admin approval)
    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True

    # 4. Notify admin
    sns.publish(TopicArn=TOPIC_ARN, Subject='New User Signup', Message=f'New signup: {email}')
    return event
```

**Environment variables:** `ALLOWED_DOMAINS`, `TURNSTILE_SECRET`, `SNS_TOPIC_ARN`

## Post-Confirmation Lambda

**Location:** `cdk/lambda/post-confirmation/index.py`

Cognito Post Confirmation trigger. Runs after the user is confirmed. Provisions tenant infrastructure:

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

    # 3. Create Tenant CR (operator reconciles → NS, PVC, SA, ArgoCD App, KEDA HSO)
    k8s_client.create_namespaced_custom_object(
        group='openclaw.io', version='v1', namespace='openclaw-system',
        plural='tenants', body={'metadata': {'name': tenant}, ...},
    )

    # 4. SNS notify admin
    # 5. SES welcome email to user with tenant URL
```

**Environment variables:** `SNS_TOPIC_ARN`, `CLUSTER_NAME`, `TENANT_ROLE_ARN`, `DOMAIN`, `SES_FROM_EMAIL`

**IAM permissions:** `secretsmanager:CreateSecret`, `eks:CreatePodIdentityAssociation`, `sns:Publish`, `ses:SendEmail`, EKS cluster access for Tenant CR creation

## Gateway Auth Mode

The OpenClaw gateway runs in `local` auth mode — authentication is handled by the gateway itself, not by ALB Cognito integration. Security is provided by the CloudFront + internal ALB architecture (ALB is not internet-facing).

Path-based routing via Gateway API:

```yaml
# HTTPRoute routes claw.your-domain.com/t/<tenant>/ to the tenant service
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openclaw-<tenant>
spec:
  parentRefs:
    - name: openclaw-gateway
  hostnames:
    - claw.your-domain.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /t/<tenant>/
      backendRefs:
        - name: openclaw-<tenant>
          port: 18789
```

```yaml
# values.yaml
config:
  gateway:
    auth:
      mode: local
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
- **Auto-confirm** — `autoConfirmUser = true`, email domain restriction is the trust gate
- **Gateway token** — `secrets.token_urlsafe(32)`, stored in Secrets Manager with ABAC tags
- **Tenant isolation** — Pod Identity scoped per namespace, Secrets Manager access via ABAC
- **Password policy** — min 12 chars, uppercase + lowercase + numbers (enforced by Cognito + UI)

## CDK Resources

| Resource | Purpose |
|----------|---------|
| `PreSignupFn` | Lambda + IAM role (sns:Publish) |
| `PostConfirmFn` | Lambda + IAM role (secretsmanager, eks, sns, ses) |

Cognito triggers are attached via `scripts/setup-signup-triggers.sh` (User Pool is imported, not CDK-managed).
