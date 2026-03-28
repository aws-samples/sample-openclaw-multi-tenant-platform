# OpenClaw Multi-Tenant Platform on EKS

Deploy isolated OpenClaw AI assistant instances on Amazon EKS — one per user, fully separated.

Each tenant gets their own namespace, persistent storage, and network isolation. LLM access is provided through Amazon Bedrock with zero API keys.

## Architecture

```
User → Browser → Cognito Login → ALB (HTTPS, *.your-domain.com)
                                  ↓ host-based routing
                              EKS Pod (OpenClaw Gateway, trusted-proxy mode)
                                  ├→ Bedrock (LLM, Pod Identity)
                                  ├→ Secrets Manager (exec SecretRef, ABAC)
                                  └→ AgentCore Browser (web browsing)
```

```
EKS Cluster (CDK, configurable region)
│  Managed Node Group (t4g.medium Graviton ARM64) + Karpenter (spot)
│  Add-ons: ALB Controller, EBS CSI, Pod Identity Agent, CloudWatch Container Insights
│  KEDA HTTP Add-on (scale-to-zero)
│
├── namespace: openclaw-{tenant}
│   ├── ServiceAccount + Pod Identity → shared IAM Role (ABAC)
│   ├── Deployment (OpenClaw Gateway)
│   │   ├── init-config (openclaw.json if not exists)
│   │   ├── init-skills (clawhub install)
│   │   ├── init-tools (AWS SDK + smithy patch + fetch-secret.mjs)
│   │   └── main (gateway --bind lan --port 18789)
│   ├── ConfigMap (openclaw.json + fetch-secret.mjs)
│   ├── PVC (gp3, 10Gi — persists across scale-to-zero)
│   ├── Service (ClusterIP:18789)
│   ├── Ingress (ALB IngressGroup, Cognito auth, host-based routing)
│   ├── NetworkPolicy (egress: DNS + Pod Identity + HTTPS only)
│   ├── HTTPScaledObject (KEDA, idle 15min → scale to 0)
│   └── ResourceQuota (4 CPU, 8Gi mem)
```

Full architecture diagrams: [`docs/architecture.md`](docs/architecture.md)

## Security Design

| Layer | Control |
|-------|---------|
| Auth | Cognito + ALB + trusted-proxy (`x-amzn-oidc-identity` header) |
| Signup | Pre-signup Lambda restricts email domain; admin approval required |
| IAM | Pod Identity ABAC — shared role, per-tenant secret isolation via namespace tag |
| Network | Egress whitelist (DNS/53, Pod Identity/80, HTTPS/443); cross-tenant blocked |
| OpenClaw | Tool deny (gateway, cron, sessions), exec=deny, elevated=disabled, fs=workspaceOnly |
| Container | UID 1000, fsGroup 1000, ResourceQuota |
| Secrets | exec SecretRef — fetched on-demand, never persisted in env/filesystem |
| LLM | Bedrock via Pod Identity — zero API keys |
| Data | PVC persists across pod restarts and scale-to-zero; daily EBS snapshot backup |

## Prerequisites

- AWS CLI v2 + configured SSO profile
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl + Helm 3
- Node.js 22+
- A domain with Route53 hosted zone + ACM wildcard certificate
- Cognito User Pool + App Client

## Quick Start

```bash
# 1. Deploy EKS cluster + infra (~15-20 min)
cd cdk && npm install
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn> --profile <profile>

# 2. Configure kubectl
aws eks update-kubeconfig --region <region> --name openclaw-cluster --profile <profile>

# 3. Install KEDA (scale-to-zero)
./scripts/setup-keda.sh

# 4. Create a tenant
./scripts/create-tenant.sh alice

# 5. (Optional) Enable self-service signup
./scripts/setup-signup-triggers.sh

# 6. (Optional) Brand the Cognito login page
./scripts/setup-cognito-branding.sh

# 7. Access via browser
# https://alice.your-domain.com → Cognito login → OpenClaw Control UI
```

## CDK Stack Outputs

| Output | Description |
|--------|-------------|
| ClusterName | EKS cluster name |
| ClusterEndpoint | EKS API endpoint |
| TenantRoleArn | Shared IAM role for all tenants |
| AlertsTopicArn | SNS topic for pod restart alerts |
| ErrorPagesBucketName | S3 bucket for custom error pages |
| PreSignupFnArn | Pre-signup Lambda ARN |
| PostConfirmFnArn | Post-confirmation Lambda ARN |
| EbsSnapshotRoleArn | IAM role for PVC backup CronJob |

## Tenant Management

```bash
./scripts/create-tenant.sh <name>              # Create tenant (--display-name --emoji --skills)
./scripts/delete-tenant.sh <name>              # Delete tenant
./scripts/verify-tenant.sh <name>              # Verify health + credentials
./scripts/check-all-tenants.sh                 # Health check all tenants
```

## Operations

```bash
./scripts/setup-cognito-branding.sh            # Cognito hosted UI branding
./scripts/setup-alerts.sh <email>              # Subscribe to CloudWatch alerts
./scripts/setup-keda.sh                        # Install KEDA for scale-to-zero
./scripts/setup-image-update.sh                # Install image auto-update CronJob
./scripts/setup-pvc-backup.sh                  # Install daily PVC backup CronJob
./scripts/setup-usage-tracking.sh              # CloudWatch usage metrics + dashboard
./scripts/setup-signup-triggers.sh             # Attach Cognito Lambda triggers
./scripts/upload-error-page.sh [bucket]        # Upload custom 503 page to S3
./scripts/usage-report.sh [--month YYYY-MM]    # Monthly per-tenant cost report
```

## Scale-to-Zero

KEDA HTTP Add-on monitors incoming requests. After 15 minutes of inactivity, the tenant pod scales to 0 replicas. The PVC (EBS volume) persists — no data is lost. When a new request arrives, KEDA scales the pod back to 1 within 15-30 seconds.

See [`docs/scale-to-zero.md`](docs/scale-to-zero.md) for details.

## Self-Service Signup

When enabled, users can register through the Cognito hosted UI. The Pre-signup Lambda restricts registration to allowed email domains. After admin approval, the Post-confirmation Lambda automatically provisions the tenant (Secrets Manager + Pod Identity + CodeBuild helm install).

See [`docs/self-service-signup.md`](docs/self-service-signup.md) for details.

## Known Issues

### @smithy/credential-provider-imds Pod Identity Bug

OpenClaw's bundled `@smithy/credential-provider-imds` rejects EKS Pod Identity Agent's IP (`169.254.170.23`). The `init-tools` container patches this via `sed` at startup. See [aws-sdk-js-v3#5709](https://github.com/aws/aws-sdk-js-v3/issues/5709).

## Cost Estimate

| Resource | 3 tenants | 100 tenants |
|----------|-----------|-------------|
| EKS control plane | ~$73 | ~$73 |
| EC2 (t4g.medium Graviton + Karpenter spot) | ~$48 | ~$48-150 |
| EBS (gp3 10Gi per tenant) | ~$2.40 | ~$80 |
| ALB | ~$16 | ~$16 |
| NAT Gateway | ~$32 | ~$32 |
| CloudWatch (Container Insights) | ~$10-15 | ~$15-30 |
| Lambda + S3 + CodeBuild | ~$0 | ~$1 |
| Bedrock (usage-based) | varies | varies |
| **Total (infra)** | **~$182-187/mo** | **~$265-382/mo** |

> KEDA scale-to-zero is active. EC2 cost scales with concurrent usage, not total tenants. 500 tenants with 20% concurrency ≈ 100 pods peak.

## Project Structure

```
├── cdk/                              # CDK stack (EKS + IAM + Lambda + S3 + CodeBuild)
│   ├── lambda/
│   │   ├── pre-signup/               # Cognito pre-signup trigger (email domain check)
│   │   └── post-confirmation/        # Cognito post-confirmation (auto tenant creation)
│   └── lib/
│       └── eks-cluster-stack.ts      # Main CDK stack
├── docs/
│   ├── architecture.md               # Full architecture diagrams (12 sections)
│   ├── scale-to-zero.md              # KEDA HTTP Add-on design
│   ├── image-update.md               # Auto image update strategy
│   ├── self-service-signup.md        # Cognito self-service signup design
│   └── usage-tracking.md             # Per-tenant Bedrock usage tracking
├── helm/
│   ├── charts/openclaw-platform/     # Helm chart (15 templates)
│   │   ├── templates/
│   │   │   ├── deployment.yaml       # Pod spec with init containers
│   │   │   ├── ingress.yaml          # ALB + Cognito auth
│   │   │   ├── networkpolicy.yaml    # Egress whitelist + cross-tenant deny
│   │   │   ├── httpscaledobject.yaml # KEDA scale-to-zero
│   │   │   └── ...
│   │   └── static/                   # Error pages (503.html, index.html)
│   └── tenants/
│       └── values-template.yaml      # Per-tenant values template
├── scripts/                          # Operations scripts (12 scripts)
└── README.md
```

## Design Docs

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | Full architecture diagrams (Mermaid + ASCII) |
| [scale-to-zero.md](docs/scale-to-zero.md) | KEDA HTTP Add-on scale-to-zero design |
| [image-update.md](docs/image-update.md) | Auto image update strategy comparison |
| [self-service-signup.md](docs/self-service-signup.md) | Cognito self-service signup + admin approval |
| [usage-tracking.md](docs/usage-tracking.md) | Per-tenant Bedrock usage tracking + cost allocation |

## Customization

To use your own domain, update these files:
- `cdk/lib/eks-cluster-stack.ts` — Route53 hosted zone ID, ACM certificate ARN, Cognito pool/client
- `helm/tenants/values-template.yaml` — `{{DOMAIN}}` and `{{COGNITO_DOMAIN}}` placeholders
- `scripts/landing-ingress.yaml` — host and Cognito URLs

## Based On

- [thepagent/openclaw-helm](https://github.com/thepagent/openclaw-helm) — Slim Helm chart
- [OpenClaw Gateway Security](https://openclaw.dev/docs/gateway/security) — Trusted-proxy mode, tool policy
- [AWS EKS Pod Identity ABAC](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS EKS Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)
