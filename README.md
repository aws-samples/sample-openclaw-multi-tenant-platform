# OpenClaw Multi-Tenant Platform on EKS

Deploy isolated OpenClaw instances on Amazon EKS — one per user, fully separated.

Domain: `*.claw.snese.net` | Auth: Cognito | LLM: Bedrock (zero API keys)

## Architecture

```
User → Browser → Cognito Login → ALB (HTTPS, *.claw.snese.net)
                                  ↓ host-based routing
                              EKS Pod (OpenClaw Gateway, trusted-proxy mode)
                                  ├→ Bedrock (LLM, Pod Identity)
                                  ├→ Secrets Manager (exec SecretRef, ABAC)
                                  └→ AgentCore Browser (web browsing)
```

```
EKS Cluster (CDK, us-west-2)
│  Managed Node Group (t4g.medium Graviton) + Karpenter (arm64 spot)
│  Add-ons: ALB Controller, EBS CSI, Pod Identity Agent, CloudWatch Container Insights
│  Optional: KEDA HTTP Add-on (scale-to-zero)
│
├── namespace: openclaw-{tenant}
│   ├── ServiceAccount + Pod Identity → shared IAM Role (ABAC)
│   ├── Deployment (OpenClaw Gateway)
│   │   ├── init-config (openclaw.json if not exists)
│   │   ├── init-skills (clawhub install weather, gog)
│   │   ├── init-tools (AWS SDK + smithy patch + fetch-secret.mjs)
│   │   └── main (gateway --bind lan --port 18789)
│   ├── ConfigMap (openclaw.json + fetch-secret.mjs)
│   ├── PVC (gp3, 10Gi)
│   ├── Service (ClusterIP:18789)
│   ├── Ingress (ALB IngressGroup, Cognito auth, host-based routing)
│   ├── NetworkPolicy (egress: DNS + Pod Identity + HTTPS only)
│   └── ResourceQuota (4 CPU, 8Gi mem, 5 pods)
```

Full architecture diagrams (Mermaid + ASCII): [`docs/architecture.md`](docs/architecture.md)

## Security Design

| Layer | Control |
|-------|---------|
| Auth | Cognito + ALB + trusted-proxy (`x-amzn-oidc-identity` header) |
| IAM | Pod Identity ABAC — shared role, per-tenant secret isolation via `tenant-namespace` tag |
| Network | Egress whitelist (DNS/53, Pod Identity/80, HTTPS/443); cross-tenant blocked |
| OpenClaw | Tool deny (gateway, cron, sessions), exec=deny, elevated=disabled, fs=workspaceOnly |
| Container | UID 1000, fsGroup 1000, ResourceQuota |
| Secrets | exec SecretRef — fetched on-demand, never persisted in env/filesystem |
| LLM | Bedrock via Pod Identity — zero API keys |

## Prerequisites

- AWS CLI v2 + configured SSO profile
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl + Helm 3
- Node.js 18+

## Quick Start

```bash
# 1. Deploy EKS cluster + infra (~15-20 min)
cd cdk && npm install
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn> --profile <profile> --region us-west-2

# 2. Configure kubectl
aws eks update-kubeconfig --region us-west-2 --name openclaw-cluster --profile <profile>

# 3. Create a tenant
./scripts/create-tenant.sh alice

# 4. Access via browser
# https://alice.claw.snese.net → Cognito login → OpenClaw Control UI

# 5. (Optional) Enable self-service signup
./scripts/setup-signup-triggers.sh
```

## CDK Stack Outputs

| Output | Description |
|--------|-------------|
| ClusterName | EKS cluster name |
| ClusterEndpoint | EKS API endpoint |
| TenantRoleArn | Shared IAM role for all tenants |
| DomainName | `claw.snese.net` |
| CertificateArn | ACM wildcard cert `*.claw.snese.net` |
| CognitoPoolId | Cognito User Pool ID |
| CognitoClientId | Cognito App Client ID |
| CognitoDomain | Cognito hosted UI domain |
| KubeconfigCommand | `aws eks update-kubeconfig ...` |
| ErrorPagesBucket | S3 bucket for custom error pages |
| PreSignupFnArn | Pre-signup Lambda ARN |
| PostConfirmFnArn | Post-confirmation Lambda ARN |
| EbsSnapshotRoleArn | IAM role for PVC backup |

## Tenant Management

```bash
./scripts/create-tenant.sh <name>              # Create tenant (supports --display-name --emoji --skills)
./scripts/delete-tenant.sh <name>              # Delete tenant
./scripts/verify-tenant.sh <name>              # Verify health + credentials
./scripts/check-all-tenants.sh                 # Health check all tenants
```

## Operations

```bash
./scripts/setup-cognito-branding.sh            # Cognito hosted UI branding (CSS + logo)
./scripts/setup-alerts.sh <email>              # Subscribe to CloudWatch alerts via SNS
./scripts/setup-keda.sh                        # Install KEDA for scale-to-zero
./scripts/setup-image-update.sh                # Install image auto-update CronJob
./scripts/upload-error-page.sh <s3-bucket>     # Upload custom 503 page for scale-to-zero
./scripts/setup-signup-triggers.sh             # Attach Cognito Lambda triggers
./scripts/setup-pvc-backup.sh                  # Install daily PVC backup CronJob
./scripts/setup-usage-tracking.sh              # CloudWatch usage metrics + dashboard
./scripts/usage-report.sh                      # Monthly per-tenant cost report
```

## Known Issues

### @smithy/credential-provider-imds Pod Identity Bug

OpenClaw's bundled `@smithy/credential-provider-imds` has `GREENGRASS_HOSTS` that only allows `localhost` and `127.0.0.1`, rejecting EKS Pod Identity Agent's `169.254.170.23`. The `init-tools` container patches this via `sed` at startup. See [aws-sdk-js-v3#5709](https://github.com/aws/aws-sdk-js-v3/issues/5709).

## Cost Estimate

| Resource | Monthly Cost (3 tenants) | At 100 tenants |
|----------|------------------------|----------------|
| EKS control plane | ~$73 | ~$73 |
| EC2 (t3.medium + Karpenter spot) | ~$60 | ~$60-150 |
| EBS (gp3 10Gi per tenant) | ~$2.40 | ~$80 |
| ALB | ~$16 | ~$16 |
| NAT Gateway | ~$32 | ~$32 |
| CloudWatch (Container Insights) | ~$10-15 | ~$15-30 |
| Lambda + S3 | ~$0 | ~$0 |
| Bedrock (usage-based) | varies | varies |
| **Total (infra)** | **~$194-199/mo** | **~$276-381/mo** |

> KEDA scale-to-zero is active. EC2 scales with concurrent usage, not total tenants.

## Project Structure

```
├── cdk/                          # CDK stacks (VPC + EKS + IAM + Cognito/ACM/Route53)
│   └── lambda/                   # Cognito trigger Lambda functions
├── docs/
│   ├── architecture.md           # Full architecture diagrams (Mermaid + ASCII)
│   ├── scale-to-zero.md          # KEDA HTTP Add-on design
│   ├── image-update.md           # Auto image update strategy
│   ├── self-service-signup.md    # Cognito self-service signup design
│   └── usage-tracking.md         # Per-tenant Bedrock usage tracking
├── helm/
│   ├── charts/openclaw-platform/ # Extended OpenClaw Helm chart
│   │   ├── templates/
│   │   │   ├── deployment.yaml       # Pod spec with init containers + smithy patch
│   │   │   ├── configmap.yaml        # openclaw.json + fetch-secret.mjs
│   │   │   ├── ingress.yaml          # ALB + Cognito auth + session timeout
│   │   │   ├── networkpolicy.yaml    # Egress whitelist + cross-tenant deny
│   │   │   ├── httpscaledobject.yaml # KEDA scale-to-zero (disabled by default)
│   │   │   └── resourcequota.yaml
│   │   ├── static/503.html           # Custom error page for scale-to-zero
│   │   └── values.yaml               # Models, security, tool policy
│   └── tenants/
│       └── values-template.yaml      # Per-tenant values template
├── scripts/
│   ├── create-tenant.sh          # SM secret + Pod Identity + helm install
│   ├── delete-tenant.sh          # Remove tenant
│   ├── verify-tenant.sh          # Verify health + credentials
│   ├── check-all-tenants.sh      # Batch health check
│   ├── setup-cognito-branding.sh # Cognito UI branding
│   ├── setup-alerts.sh           # SNS alert subscription
│   ├── setup-keda.sh             # KEDA installation
│   ├── setup-image-update.sh     # Image update CronJob
│   ├── upload-error-page.sh      # S3 error page upload
│   ├── setup-signup-triggers.sh  # Cognito Lambda triggers
│   ├── setup-pvc-backup.sh       # Daily PVC backup CronJob
│   ├── setup-usage-tracking.sh   # CloudWatch usage metrics + dashboard
│   └── usage-report.sh           # Monthly per-tenant cost report
└── README.md
```

## Design Docs

| Document | Description |
|----------|-------------|
| [docs/architecture.md](docs/architecture.md) | Full architecture diagrams (Mermaid + ASCII) |
| [docs/scale-to-zero.md](docs/scale-to-zero.md) | KEDA HTTP Add-on scale-to-zero design |
| [docs/image-update.md](docs/image-update.md) | Auto image update strategy comparison |
| [docs/self-service-signup.md](docs/self-service-signup.md) | Cognito self-service signup + HC approval |
| [docs/usage-tracking.md](docs/usage-tracking.md) | Per-tenant Bedrock usage tracking + cost split |

## Based On

- [thepagent/openclaw-helm](https://github.com/thepagent/openclaw-helm) — slim Helm chart
- [OpenClaw Gateway Security](https://openclaw.dev/docs/gateway/security) — trusted-proxy mode, tool policy
- [AWS EKS Pod Identity ABAC](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS EKS Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)
