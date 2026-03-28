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
│  Managed Node Group + Karpenter
│  Add-ons: ALB Controller, EBS CSI, Pod Identity Agent
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

## Tenant Management

```bash
./scripts/create-tenant.sh <name>    # Create tenant
./scripts/delete-tenant.sh <name>    # Delete tenant
./scripts/verify-tenant.sh <name>    # Verify health + credentials
```

## Known Issues

### @smithy/credential-provider-imds Pod Identity Bug

OpenClaw's bundled `@smithy/credential-provider-imds` has `GREENGRASS_HOSTS` that only allows `localhost` and `127.0.0.1`, rejecting EKS Pod Identity Agent's `169.254.170.23`. The `init-tools` container patches this via `sed` at startup. See [aws-sdk-js-v3#5709](https://github.com/aws/aws-sdk-js-v3/issues/5709).

## Cost Estimate (3 tenants)

| Resource | Monthly Cost |
|----------|-------------|
| EKS control plane | ~$73 |
| EC2 (2x t3.medium) | ~$60 |
| EBS (3x 10Gi gp3) | ~$2.40 |
| ALB | ~$16 |
| NAT Gateway | ~$32 |
| Bedrock (usage-based) | varies |
| **Total (infra only)** | **~$184/mo** |

## Project Structure

```
├── cdk/                          # CDK stack (EKS + IAM + Cognito/ACM/Route53 imports)
├── docs/architecture.md          # Full architecture diagrams (Mermaid + ASCII)
├── helm/charts/openclaw-platform # Extended OpenClaw Helm chart
│   ├── templates/
│   │   ├── deployment.yaml       # Pod spec with init containers + smithy patch
│   │   ├── configmap.yaml        # openclaw.json (dynamic allowedOrigins) + fetch-secret.mjs
│   │   ├── ingress.yaml          # ALB + Cognito auth annotations
│   │   ├── networkpolicy.yaml    # Egress whitelist + cross-tenant deny
│   │   └── resourcequota.yaml
│   └── values.yaml               # Models, security hardening, tool policy
├── scripts/
│   ├── create-tenant.sh          # SM secret + Pod Identity + helm install
│   ├── delete-tenant.sh
│   └── verify-tenant.sh
└── README.md
```

## Based On

- [thepagent/openclaw-helm](https://github.com/thepagent/openclaw-helm) — slim Helm chart
- [OpenClaw Gateway Security](https://openclaw.dev/docs/gateway/security) — trusted-proxy mode, tool policy
- [AWS EKS Pod Identity ABAC](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS EKS Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)
