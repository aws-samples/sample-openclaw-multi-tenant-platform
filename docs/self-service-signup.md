# Self-Service Signup: Cognito + Lambda Auto-Provisioning

## Goal

Allow users to register through Cognito Hosted UI. After admin approval, the system automatically provisions a new tenant (Secrets Manager secret + Pod Identity + Helm install via CodeBuild).

## Architecture

```
User → Cognito Hosted UI → Sign Up
                             ↓
                       Pre-Signup Lambda
                       ├─ Validate email domain (reject if not allowed)
                       ├─ autoConfirmUser = false (requires admin approval)
                       └─ SNS notify admin: "New signup: {email}"
                             ↓
                       Admin confirms user in Cognito Console
                             ↓
                       Post-Confirmation Lambda
                       ├─ Sanitize tenant name from email
                       ├─ Create Secrets Manager secret (gateway token)
                       ├─ Create Pod Identity Association
                       ├─ Trigger CodeBuild (helm install)
                       └─ SNS notify user: "Your URL is {tenant}.your-domain.com"
                             ↓
                       CodeBuild runs helm install
                             ↓
                       Tenant pod ready (~2 min)
```

## Pre-Signup Lambda

- Runtime: Python 3.12
- Checks email domain against `ALLOWED_DOMAINS` env var
- Rejects non-matching domains with an exception
- Sets `autoConfirmUser = false` (admin must approve)
- Publishes SNS notification to admin

```python
ALLOWED_DOMAINS = os.environ.get('ALLOWED_DOMAINS', 'example.com').split(',')

def handler(event, context):
    email = event['request']['userAttributes'].get('email', '')
    domain = email.split('@')[-1].lower()
    if domain not in ALLOWED_DOMAINS:
        raise Exception(f'Email domain not allowed: {domain}')
    event['response']['autoConfirmUser'] = False
    event['response']['autoVerifyEmail'] = True
    # SNS notify admin
    return event
```

## Post-Confirmation Lambda

- Runtime: Python 3.12
- Sanitizes tenant name: email local part, `[a-z0-9-]` only, max 20 chars
- Creates Secrets Manager secret with `tenant-namespace` tag (for ABAC)
- Creates EKS Pod Identity Association
- Triggers CodeBuild project to run `helm install`
- Notifies user via SNS

## CodeBuild Project

- `openclaw-tenant-builder` (managed by CDK)
- Installs kubectl + helm, runs `helm install` for the new tenant
- Source: GitHub repo (configurable in CDK context)

## Security

- Pre-signup Lambda rejects non-allowed email domains
- Admin approval required before any resources are created
- Tenant name sanitized: `[a-z0-9-]`, max 20 characters
- Gateway token generated with `secrets.token_urlsafe(32)`
- Secrets Manager secret tagged for ABAC isolation

## Cost

All components fall within AWS free tier for typical usage:
- Lambda: ~10 invocations/month
- CodeBuild: ~10 builds/month (100 free build-minutes)
- SNS: negligible

## CDK Resources

The following resources are created by CDK:
- `PreSignupFn` — Lambda function + IAM role (sns:Publish)
- `PostConfirmFn` — Lambda function + IAM role (secretsmanager, eks, codebuild, sns)
- `TenantBuilder` — CodeBuild project + IAM role (eks:DescribeCluster, system:masters)

Cognito triggers are attached via `scripts/setup-signup-triggers.sh` (not CDK, because the User Pool is imported).

## Future Improvements

- Custom Message Lambda for branded confirmation emails
- Cognito custom attributes for quota/plan management
- Direct SES email notification to users (instead of SNS)
- Kubernetes Operator (CRD) to replace CodeBuild for tenant provisioning
