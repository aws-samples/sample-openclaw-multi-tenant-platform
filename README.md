<p align="center">
  <img src="https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-eks&logoColor=white" alt="EKS">
  <img src="https://img.shields.io/badge/AWS-CDK-FF9900?logo=amazon-aws&logoColor=white" alt="CDK">
  <img src="https://img.shields.io/badge/Bedrock-LLM-8B5CF6?logo=amazon-aws&logoColor=white" alt="Bedrock">
  <img src="https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?logo=argo&logoColor=white" alt="ArgoCD">
  <img src="https://img.shields.io/badge/KEDA-Scale--to--Zero-326CE5?logo=kubernetes&logoColor=white" alt="KEDA">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT">
</p>

# OpenClaw Platform

> Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated, private AI workspace powered by Amazon Bedrock — zero API keys, zero shared data.

Deploy in 20 minutes. Scale to 500 users. Pay only for what you use.

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [Tenant Management](#tenant-management)
- [Operations](#operations)
- [Security](#security)
- [Cost](#cost)
- [Documentation](#documentation)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

## Features

- **One tenant per user** — isolated namespace, PVC, network policy, IAM role
- **Zero API keys** — LLM access via Amazon Bedrock + Pod Identity
- **Scale to zero** — KEDA scales idle pods to 0; cold start in 15-30s
- **Internal ALB** — not internet-facing; all traffic through CloudFront + WAF
- **Custom auth UI** — branded login/signup on your domain (no Cognito Hosted UI)
- **Self-service signup** — Cognito + Lambda auto-provisions tenants on auto-provisioning
- **GitOps** — ArgoCD (EKS Capability) manages tenants via ApplicationSet
- **Cost control** — per-tenant monthly budget with per-model pricing alerts
- **Graviton ARM64** — 20% cheaper compute with t4g instances
- **Security deep-dive** — 10 layers, threat model, compliance considerations

## Architecture

```
Internet
  │
  ├─ your-domain.com ──► CloudFront #1 ──► S3 (custom auth UI)
  │
  ├─ *.your-domain.com ──► CloudFront #2 ──► VPC Origin ──► Internal ALB ──► EKS Pod
  │                                                          (WAF attached)
  │
  └─ Outbound only: EKS Pod ──► NAT Gateway (HA) ──► Internet
```

```
EKS Cluster
│  Managed Node Group (Graviton ARM64) + Karpenter (arm64 spot)
│  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
│  ArgoCD (EKS Capability) + KEDA HTTP Add-on
│
├── namespace: openclaw-{tenant}
│   ├── Deployment + PVC (persists across scale-to-zero)
│   ├── Ingress (internal ALB, Cognito auth)
│   ├── HTTPScaledObject (KEDA, 15min idle → 0)
│   ├── NetworkPolicy (cross-tenant blocked)
│   └── ResourceQuota
```

## Getting Started

### Prerequisites

- AWS CLI v2 + configured profile
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl + Helm 3
- Node.js 22+
- Route53 hosted zone + ACM certificates (deployment region + us-east-1)
- Cognito User Pool + App Client (**no client secret** — public client for SPA)
- AWS Identity Center (for ArgoCD EKS Capability)

### 1. Configure

```bash
cp cdk/cdk.json.example cdk/cdk.json
# Edit cdk/cdk.json — fill in all 11 context values
```

<details>
<summary>Context values reference</summary>

| Key | Description |
|-----|-------------|
| `hostedZoneId` | Route53 hosted zone ID |
| `zoneName` | Your domain (e.g., `platform.company.com`) |
| `certificateArn` | ACM cert in deployment region (`domain` + `*.domain`) |
| `cloudfrontCertificateArn` | ACM cert in us-east-1 (`domain` + `*.domain`) |
| `cognitoPoolId` | Cognito User Pool ID |
| `cognitoClientId` | Cognito App Client ID (**no secret**) |
| `cognitoDomain` | Cognito domain prefix |
| `allowedEmailDomains` | Comma-separated allowed email domains |
| `githubOwner` | GitHub org/user for CodeBuild source |
| `githubRepo` | Repository name (default: `openclaw-platform`) |
| `ssoRoleArn` | IAM SSO role ARN for kubectl access |
| `selfSignupEnabled` | Allow users to self-register (default: `true`) |
| `defaultTenantBudgetUsd` | Monthly Bedrock budget per tenant in USD (default: `100`) |
| `defaultTenantSkills` | Default skills for new tenants (default: `weather,gog`) |
| `sesFromEmail` | SES sender email for welcome emails (default: `noreply@<domain>`) |

</details>

### 2. Deploy Infrastructure

```bash
cd cdk && npm install
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn>
```

Creates: EKS cluster, VPC (2 NAT Gateways), IAM roles, Lambda functions, S3 buckets, CloudFront, WAF, CloudWatch, SNS, CodeBuild. Takes ~15-20 minutes.

### 3. Post-Deploy Setup

```bash
# Configure kubectl
aws eks update-kubeconfig --region <region> --name openclaw-cluster

# Core setup
./scripts/setup-keda.sh                    # Scale-to-zero
./scripts/setup-cognito.sh                 # Auth configuration
./scripts/setup-argocd.sh                  # ArgoCD EKS Capability status

# Monitoring
./scripts/setup-pvc-backup.sh              # Daily PVC backups
./scripts/setup-image-update.sh            # Auto image updates
./scripts/setup-usage-tracking.sh          # Usage dashboard
./scripts/setup-bedrock-latency.sh         # Latency alarms
./scripts/setup-coldstart-alarm.sh         # Cold start alarms
./scripts/setup-audit-logging.sh           # CloudTrail + Athena
./scripts/setup-alerts.sh <email>          # SNS email alerts
```

### 4. Create First Tenant

```bash
export OPENCLAW_TENANT_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query 'Stacks[0].Outputs[?OutputKey==`TenantRoleArn`].OutputValue' --output text)

./scripts/create-tenant.sh alice --display-name "Alice" --emoji "🤖"
```

### 5. Finalize

```bash
./scripts/post-deploy.sh          # VPC Origin + CloudFront #2 + Route53 + WAF→ALB
./scripts/deploy-auth-ui.sh       # Upload auth UI to S3
./scripts/setup-argocd-apps.sh    # ArgoCD Applications + ApplicationSets
```

### 6. Access

| URL | Purpose |
|-----|---------|
| `https://your-domain.com` | Landing page (custom auth UI) |
| `https://alice.your-domain.com` | Tenant AI assistant |
| `https://your-domain.com/admin.html` | Admin dashboard |

## Tenant Management

```bash
./scripts/create-tenant.sh <name> [options]    # Create (--display-name --emoji --skills --budget)
./scripts/delete-tenant.sh <name>              # Delete (with confirmation)
./scripts/verify-tenant.sh <name>              # Health check
./scripts/check-all-tenants.sh                 # Check all tenants
./scripts/backup-tenant.sh <name> <bucket>     # Backup to S3
./scripts/restore-tenant.sh <name> <s3-path>   # Restore from S3
./scripts/admin-list-tenants.sh                # List tenants + cost
```

## Operations

| Script | Purpose |
|--------|---------|
| `post-deploy.sh` | VPC Origin + CloudFront #2 + Route53 + WAF |
| `deploy-auth-ui.sh` | Upload auth UI to S3 + invalidate cache |
| `upload-helm-chart.sh` | Package and upload Helm chart to S3 (for CodeBuild) |
| `setup-cognito.sh` | Cognito config (auth flows, triggers) |
| `setup-keda.sh` | Install KEDA for scale-to-zero |
| `setup-argocd.sh` | ArgoCD EKS Capability status |
| `setup-argocd-apps.sh` | Apply ArgoCD Applications |
| `health-check.sh` | Platform health (JSON output) |
| `usage-report.sh --month YYYY-MM` | Monthly per-tenant cost report |

## Security

| Layer | Control |
|-------|---------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | Cloudflare Turnstile CAPTCHA + email domain restriction |
| Network | ALB is **internal** — not accessible from internet |
| Auth | Cognito + ALB trusted-proxy |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef — fetched on-demand, never persisted |
| LLM | Bedrock via Pod Identity — zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero; daily EBS snapshots |
| Audit | CloudTrail + S3 + Athena |

## Cost

| Resource | 3 tenants | 100 tenants |
|----------|-----------|-------------|
| EKS control plane | ~$73 | ~$73 |
| EC2 (Graviton + Karpenter spot) | ~$48 | ~$48-150 |
| EBS (10Gi per tenant) | ~$2 | ~$80 |
| ALB + NAT (x2) + CloudFront + WAF | ~$60 | ~$65 |
| CloudWatch + Lambda + S3 | ~$15 | ~$20 |
| Bedrock | varies | varies |
| **Total (infra)** | **~$198/mo** | **~$286-388/mo** |

> KEDA scale-to-zero active. EC2 scales with concurrent usage, not total tenants.

## Documentation

### Architecture
- [System Architecture](docs/architecture.md)
- [Security Deep Dive](docs/security.md)

### Components
Learn how each component works:
| Component | Description |
|-----------|-------------|
| [EKS Cluster](docs/components/eks-cluster.md) | Cluster, nodegroups, Karpenter, add-ons |
| [Networking](docs/components/networking.md) | VPC, CloudFront, VPC Origin, WAF |
| [Auth](docs/components/auth.md) | Cognito, custom UI, Lambda triggers |
| [IAM](docs/components/iam.md) | Pod Identity, ABAC, tenant isolation |
| [Scaling](docs/components/scaling.md) | KEDA scale-to-zero, cold start |
| [GitOps](docs/components/gitops.md) | ArgoCD EKS Capability |
| [Observability](docs/components/observability.md) | CloudWatch, alarms, cost tracking |
| [CI/CD](docs/components/cicd.md) | GitHub Actions, CodeBuild, image updates |
| [Storage](docs/components/storage.md) | PVC, EBS snapshots, backup/restore |

### Operations
| Guide | Description |
|-------|-------------|
| [Admin Guide](docs/operations/admin-guide.md) | Deploy, manage, monitor |
| [User Guide](docs/operations/user-guide.md) | Signup, login, daily use |
| [Migration](docs/operations/migration.md) | v1 → v2 upgrade |
| [Webhook Setup](docs/operations/webhook.md) | Slack/Discord integration |

### Design (Future)
| Design | Description |
|--------|-------------|
| [Tenant CRD](docs/design/tenant-crd.md) | Kubernetes Operator |
| [Multi-Region](docs/design/multi-region.md) | DR architecture |
| [Terraform](docs/design/terraform.md) | IaC alternative |

## Project Structure

```
├── auth-ui/                    # Custom login/signup (S3 + CloudFront)
│   ├── index.html              # Auth UI (Cognito SDK, CAPTCHA, PWA)
│   ├── admin.html              # Admin dashboard
│   └── terms.html, privacy.html, manifest.json
├── cdk/                        # AWS CDK infrastructure
│   ├── lib/eks-cluster-stack.ts
│   ├── lambda/                 # Pre-signup, Post-confirmation, Cost-enforcer
│   └── cdk.json.example        # Config template (11 context values)
├── helm/                       # Helm chart + tenant templates
│   ├── charts/openclaw-platform/
│   └── tenants/values-template.yaml
├── argocd/                     # ArgoCD Applications + ApplicationSets
├── docs/                       # Architecture, security, components, operations, design
│   ├── architecture.md
│   ├── security.md
│   ├── components/             # Per-component deep dives
│   ├── operations/             # Admin, user, migration, webhook guides
│   └── design/                 # Future: Tenant CRD, multi-region, Terraform
├── scripts/                    # 20 operations scripts
├── .github/workflows/ci.yml   # CI pipeline
└── LICENSE                     # MIT
```

<details>
<summary>What CDK manages vs post-deploy scripts</summary>

| CDK (`cdk deploy`) | Scripts (post-deploy) |
|--------------------|-----------------------|
| EKS + VPC + IAM | KEDA installation |
| Lambda functions | Cognito configuration |
| S3 buckets | VPC Origin |
| CloudFront #1 (auth UI) | CloudFront #2 (tenants) |
| WAF WebACL | Route53 records |
| CloudWatch + SNS | WAF → ALB association |
| CodeBuild | CronJobs + dashboards |

ALB is created dynamically by Kubernetes LB Controller — CDK cannot reference it at deploy time.

</details>

## Contributing

Contributions welcome. Please open an issue first to discuss changes.

## License

[MIT](LICENSE)

---

<p align="center">
  Built with ❤️ on <a href="https://aws.amazon.com/eks/">Amazon EKS</a> + <a href="https://aws.amazon.com/bedrock/">Amazon Bedrock</a>
</p>
