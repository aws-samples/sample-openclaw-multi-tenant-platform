# OpenClaw Multi-Tenant Platform on EKS

Deploy isolated OpenClaw AI assistant instances on Amazon EKS — one per user, fully separated. All traffic flows through CloudFront with WAF protection. The ALB is internal (not internet-facing).

## Architecture

```
Internet
  │
  ├─ your-domain.com ──► CloudFront #1 ──► S3 (custom auth UI)
  │                       (login/signup page, Cognito SDK)
  │
  ├─ *.your-domain.com ──► CloudFront #2 ──► VPC Origin ──► Internal ALB ──► EKS Pod
  │                         (tenant traffic)                  (WAF attached)
  │
  └─ Outbound only: EKS Pod ──► NAT Gateway ──► Internet
                    (Telegram long-polling, Bedrock API, etc.)
```

```
EKS Cluster (CDK)
│  Managed Node Group (Graviton ARM64) + Karpenter (spot)
│  Add-ons: ALB Controller, EBS CSI, Pod Identity Agent, CloudWatch Container Insights
│  KEDA HTTP Add-on (scale-to-zero)
│
├── namespace: openclaw-{tenant}
│   ├── ServiceAccount + Pod Identity → shared IAM Role (ABAC)
│   ├── Deployment (OpenClaw Gateway)
│   ├── PVC (gp3, 10Gi — persists across scale-to-zero)
│   ├── Ingress (ALB IngressGroup, internal scheme, Cognito auth)
│   ├── HTTPScaledObject (KEDA, idle 15min → scale to 0)
│   ├── NetworkPolicy (egress whitelist, cross-tenant blocked)
│   └── ResourceQuota (4 CPU, 8Gi mem)
```

Full diagrams: [`docs/architecture.md`](docs/architecture.md)

## Security Design

| Layer | Control |
|-------|---------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit 2000/IP) |
| Network | ALB is **internal** — not accessible from internet |
| Auth | Cognito + ALB trusted-proxy (`x-amzn-oidc-identity` header) |
| Signup | Pre-signup Lambda restricts email domain; admin approval required |
| IAM | Pod Identity ABAC — shared role, per-tenant secret isolation |
| Tenant | NetworkPolicy blocks cross-namespace traffic |
| OpenClaw | Tool deny (gateway, cron, sessions), exec=deny, fs=workspaceOnly |
| Container | UID 1000, fsGroup 1000, ResourceQuota |
| Secrets | exec SecretRef — fetched on-demand, never persisted |
| LLM | Bedrock via Pod Identity — zero API keys |
| Data | PVC persists across scale-to-zero; daily EBS snapshot backup |

## Prerequisites

- AWS CLI v2 + configured profile
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl + Helm 3
- Node.js 22+
- A Route53 hosted zone for your domain
- ACM certificates:
  - One in your deployment region (for ALB)
  - One in us-east-1 (for CloudFront)
  - Both covering `your-domain.com` + `*.your-domain.com`
- Cognito User Pool + App Client

## Quick Start

### 1. Configure CDK

Copy `cdk/cdk.json.example` to `cdk/cdk.json` and fill in your values:

```json
{
  "context": {
    "hostedZoneId": "Z0123...",
    "zoneName": "your-domain.com",
    "certificateArn": "arn:aws:acm:us-west-2:...",
    "cloudfrontCertificateArn": "arn:aws:acm:us-east-1:...",
    "cognitoPoolId": "us-west-2_...",
    "cognitoClientId": "...",
    "cognitoDomain": "your-app",
    "allowedEmailDomains": "your-company.com",
    "githubOwner": "your-org"
  }
}
```

### 2. Deploy Infrastructure (~15-20 min)

```bash
cd cdk && npm install
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn>
```

This creates: EKS cluster, VPC, IAM roles, Lambda functions, S3 buckets, CloudFront #1 (auth UI), WAF, CloudWatch monitoring, SNS alerts, CodeBuild project.

### 3. Post-Deploy: Kubernetes Setup

```bash
# Configure kubectl
aws eks update-kubeconfig --region <region> --name openclaw-cluster

# Install KEDA (scale-to-zero)
./scripts/setup-keda.sh

# Configure Cognito (auth flows, triggers, branding)
./scripts/setup-cognito.sh

# Install backup and auto-update CronJobs
./scripts/setup-pvc-backup.sh
./scripts/setup-image-update.sh

# Set up usage tracking dashboard
./scripts/setup-usage-tracking.sh
```

### 4. Create First Tenant

```bash
# Set the tenant IAM role ARN (from CDK output TenantRoleArn)
export OPENCLAW_TENANT_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack --query 'Stacks[0].Outputs[?OutputKey==`TenantRoleArn`].OutputValue' --output text)

./scripts/create-tenant.sh alice --display-name "Alice" --emoji "🤖"
```

### 5. Post-Deploy: ALB-Dependent Resources

After the first tenant creates the internal ALB:

```bash
./scripts/post-deploy.sh
```

This creates: VPC Origin → internal ALB, CloudFront #2 (`*.your-domain.com`), Route53 records, WAF → ALB association.

### 6. Deploy Auth UI

```bash
./scripts/deploy-auth-ui.sh
```

### 7. Access

- Landing page: `https://your-domain.com` (custom auth UI)
- Tenant: `https://alice.your-domain.com` → Cognito auth → OpenClaw

## Tenant Management

```bash
./scripts/create-tenant.sh <name>              # Create (--display-name --emoji --skills)
./scripts/delete-tenant.sh <name>              # Delete
./scripts/verify-tenant.sh <name>              # Health check
./scripts/check-all-tenants.sh                 # Check all tenants
```

## Operations

```bash
./scripts/post-deploy.sh                       # VPC Origin + CloudFront #2 + Route53 + WAF
./scripts/deploy-auth-ui.sh                    # Upload auth UI to S3 + invalidate CloudFront
./scripts/setup-cognito.sh                     # Cognito config (auth flows, triggers, branding)
./scripts/setup-cognito-branding.sh            # Cognito hosted UI branding (fallback)
./scripts/setup-keda.sh                        # Install KEDA for scale-to-zero
./scripts/setup-alerts.sh <email>              # Subscribe to CloudWatch alerts
./scripts/setup-pvc-backup.sh                  # Daily PVC backup CronJob
./scripts/setup-image-update.sh                # Image auto-update CronJob
./scripts/setup-usage-tracking.sh              # CloudWatch usage dashboard
./scripts/setup-waf.sh                         # WAF → ALB (also done by post-deploy.sh)
./scripts/usage-report.sh [--month YYYY-MM]    # Monthly cost report
./scripts/setup-argocd-apps.sh                 # ArgoCD Applications + ApplicationSets
./scripts/setup-audit-logging.sh [region]      # CloudTrail + S3 + Athena for Bedrock audit
```

### ArgoCD (GitOps)

ArgoCD manages platform components and tenant deployments via GitOps:

```bash
# Apply all ArgoCD resources
./scripts/setup-argocd-apps.sh

# Check status
kubectl get applications -n argocd
kubectl get applicationsets -n argocd
```

- `argocd/applications/platform.yaml` — KEDA + HTTP Add-on (replaces manual `setup-keda.sh`)
- `argocd/applicationsets/tenants.yaml` — Auto-discovers `helm/tenants/values-*.yaml`, creates one Application per tenant

> Replace `<YOUR_GITHUB_ORG>` in `argocd/applicationsets/tenants.yaml` with your GitHub org/user before applying.

## Scale-to-Zero

KEDA scales idle tenant pods to 0 after 15 minutes. PVC (EBS) persists — no data loss. Cold start: 15-30 seconds. See [`docs/scale-to-zero.md`](docs/scale-to-zero.md).

## Self-Service Signup

Users register via custom auth UI → Cognito SDK → email verification → admin approval → Lambda auto-provisions tenant. See [`docs/self-service-signup.md`](docs/self-service-signup.md).

## Known Issues

### @smithy/credential-provider-imds Pod Identity Bug

OpenClaw's bundled `@smithy/credential-provider-imds` rejects EKS Pod Identity Agent IP. The `init-tools` container patches this at startup. See [aws-sdk-js-v3#5709](https://github.com/aws/aws-sdk-js-v3/issues/5709).

### NAT Gateway HA and Nodegroup Changes Require VPC Rebuild

CDK has been updated to `natGateways: 2` (HA) and `system-graviton` nodegroup (t4g.medium/arm64), but these changes cannot be applied in-place to an existing stack — CloudFormation requires a VPC rebuild, which disrupts the EKS cluster.

Existing environments keep `natGateways: 1` + a manually created `system-graviton` nodegroup. New deployments automatically use the new settings.

To migrate from v1 to v2, see [`docs/migration-guide.md`](docs/migration-guide.md).

## Cost Estimate

| Resource | 3 tenants | 100 tenants |
|----------|-----------|-------------|
| EKS control plane | ~$73 | ~$73 |
| EC2 (Graviton t4g.medium + Karpenter spot) | ~$48 | ~$48-150 |
| EBS (gp3 10Gi per tenant) | ~$2.40 | ~$80 |
| ALB (internal) | ~$16 | ~$16 |
| NAT Gateway | ~$32 | ~$32 |
| CloudFront (2 distributions) | ~$1 | ~$5-20 |
| CloudWatch | ~$10-15 | ~$15-30 |
| WAF | ~$5 | ~$5-10 |
| Lambda + S3 + CodeBuild | ~$0 | ~$1 |
| Bedrock (usage-based) | varies | varies |
| **Total (infra)** | **~$188-193/mo** | **~$275-417/mo** |

> KEDA scale-to-zero active. EC2 scales with concurrent usage, not total tenants.

## Project Structure

```
├── argocd/                           # ArgoCD GitOps manifests
│   ├── applications/
│   │   └── platform.yaml             # KEDA + HTTP Add-on
│   └── applicationsets/
│       └── tenants.yaml              # Auto-discover tenants from helm/tenants/
├── auth-ui/                          # Custom login/signup page (S3 + CloudFront)
│   └── index.html                    # AI-Native design, Cognito SDK
├── cdk/                              # CDK stack
│   ├── lambda/
│   │   ├── pre-signup/               # Email domain restriction
│   │   └── post-confirmation/        # Auto tenant provisioning
│   ├── lib/
│   │   └── eks-cluster-stack.ts      # Main stack
│   ├── cdk.json.example              # Config template (fill in your values)
│   └── cdk.json                      # Your config (gitignored)
├── docs/
│   ├── architecture.md               # Full architecture diagrams
│   ├── scale-to-zero.md              # KEDA design
│   ├── image-update.md               # Auto image update
│   ├── self-service-signup.md        # Cognito signup flow
│   └── usage-tracking.md             # Per-tenant cost tracking
├── helm/
│   ├── charts/openclaw-platform/     # Helm chart (15 templates)
│   │   ├── templates/                # Deployment, Ingress (internal), NetworkPolicy, KEDA, etc.
│   │   └── static/                   # Error pages
│   └── tenants/
│       └── values-template.yaml      # Per-tenant config template
├── scripts/                          # 15 operations scripts
│   ├── post-deploy.sh                # VPC Origin + CloudFront #2 + Route53 + WAF
│   ├── deploy-auth-ui.sh             # Upload auth UI to S3
│   ├── create-tenant.sh              # Create tenant
│   ├── setup-cognito.sh              # Cognito configuration
│   ├── setup-keda.sh                 # KEDA installation
│   ├── setup-argocd-apps.sh          # ArgoCD Applications + ApplicationSets
│   └── ...
└── README.md
```

## Design Docs

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | Full architecture diagrams |
| [scale-to-zero.md](docs/scale-to-zero.md) | KEDA scale-to-zero design |
| [image-update.md](docs/image-update.md) | Auto image update strategy |
| [self-service-signup.md](docs/self-service-signup.md) | Cognito signup + auto provisioning |
| [usage-tracking.md](docs/usage-tracking.md) | Per-tenant cost tracking |
| [migration-guide.md](docs/migration-guide.md) | v1 → v2 migration (VPC rebuild) |

## What CDK Manages vs Scripts

| CDK (`cdk deploy`) | Scripts (post-deploy) |
|--------------------|-----------------------|
| EKS cluster + VPC | KEDA installation |
| IAM roles | Cognito configuration |
| Lambda functions | VPC Origin |
| S3 buckets | CloudFront #2 (tenant traffic) |
| CloudFront #1 (auth UI) | Route53 records |
| WAF WebACL | WAF → ALB association |
| CloudWatch + SNS | CronJobs |
| CodeBuild | Usage dashboard |

Reason: ALB is created dynamically by Kubernetes LB Controller. CDK cannot reference it at deploy time.

## Customization

Fill in `cdk/cdk.json` with your values. All domain/account-specific config is read from CDK context. No hardcoded secrets in the repo.

## Based On

- [thepagent/openclaw-helm](https://github.com/thepagent/openclaw-helm) — Slim Helm chart
- [OpenClaw Gateway Security](https://openclaw.dev/docs/gateway/security) — Trusted-proxy mode
- [AWS EKS Pod Identity ABAC](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS CloudFront VPC Origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
