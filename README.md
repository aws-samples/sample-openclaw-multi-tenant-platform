<p align="center">
  <img src="https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-eks&logoColor=white" alt="EKS">
  <img src="https://img.shields.io/badge/AWS-CDK-FF9900?logo=amazon-aws&logoColor=white" alt="CDK">
  <img src="https://img.shields.io/badge/Bedrock-LLM-8B5CF6?logo=amazon-aws&logoColor=white" alt="Bedrock">
  <img src="https://img.shields.io/badge/KEDA-Scale--to--Zero-326CE5?logo=kubernetes&logoColor=white" alt="KEDA">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT">
</p>

# OpenClaw Platform

> Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated, private AI workspace powered by Amazon Bedrock -- zero API keys, zero shared data.

Deploy in 20 minutes. Scale to 500 users. Pay only for what you use.

> **Important:** This is a sample project for demonstration and learning. Not intended for production without thorough review and hardening. See [Security](docs/security.md) for known gaps.

## Features

- **One tenant per user** -- isolated namespace, PVC, network policy, IAM role
- **Zero API keys** -- LLM access via Amazon Bedrock + Pod Identity
- **Scale to zero** -- KEDA scales idle pods to 0; cold start in 15-30s
- **3-layer origin protection** -- internet-facing ALB with CF-only SG + WAF + HTTPS
- **Custom auth UI** -- branded login/signup on your domain (no Cognito Hosted UI)
- **Self-service signup** -- Cognito + Lambda auto-provisions tenants
- **Operator + ArgoCD managed** -- Operator creates NS/PVC/SA/ArgoCD App/KEDA HSO; ArgoCD syncs Helm chart for remaining resources ([details](docs/architecture.md))
- **Cost control** -- per-tenant monthly budget with per-model pricing alerts
- **Graviton ARM64** -- 20% cheaper compute with t4g instances

## Architecture

Path-based routing via Gateway API: `claw.example.com/t/<tenant>/` -- one domain, one ALB, no wildcard DNS needed.

```
Internet
  |
  +- your-domain.com --> CloudFront #1 --> S3 (custom auth UI)
  |
  +- claw.your-domain.com --> CloudFront #2 --> Internet-facing ALB --> EKS Pod
  |                                               (CF-only SG + WAF)
  |
  +- Outbound only: EKS Pod --> NAT Gateway (HA) --> Internet
```

```
EKS Cluster
|  Managed Node Group (Graviton ARM64) + Karpenter (arm64 spot)
|  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   Operator-managed (SSA):        ArgoCD-managed (Helm chart):
|     Namespace                      Deployment + Service + ConfigMap
|     PVC (10Gi gp3)                 HTTPRoute + TargetGroupConfiguration
|     ServiceAccount (Pod Identity)  NetworkPolicy + ResourceQuota + PDB
|     KEDA HSO
|   ArgoCD Application (in argocd namespace, points to helm/charts/openclaw-platform)
```

## Getting Started

### Quick Start

```bash
git clone https://github.com/snese/sample-openclaw-multi-tenant-platform.git
cd sample-openclaw-multi-tenant-platform
./setup.sh
```

`setup.sh` checks prerequisites, prompts for configuration, and deploys everything (~20 min).

### Step-by-Step

#### Prerequisites

- AWS CLI v2 + configured profile
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl + Helm 3, Node.js 22+, Docker
- Route53 hosted zone + ACM certificates (deployment region + us-east-1)
- Cognito User Pool + App Client (**no client secret** -- public client for SPA)

#### 1. Configure

```bash
cp cdk/cdk.json.example cdk/cdk.json
# Edit cdk/cdk.json -- fill in context values (see cdk.json.example for full list)
```

#### 2. Deploy Infrastructure

```bash
cd cdk && npm install
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn>
```

Creates: EKS cluster, VPC, IAM roles, Lambda, S3, CloudFront, WAF, CloudWatch, SNS (~15-20 min).

#### 3. Deploy Operator

```bash
aws eks update-kubeconfig --region <region> --name openclaw-cluster
kubectl apply -f operator/yaml/crd.yaml
kubectl apply -f operator/yaml/deployment.yaml
```

The Operator image is pre-built and published to GHCR (`ghcr.io/snese/openclaw-tenant-operator`). EKS pulls it automatically via ECR pull-through cache -- no local Docker or Rust toolchain needed.

> **Customizing the Operator**: If you modify `operator/src/`, use `scripts/build-operator.sh` to build and push your own image to ECR.

#### 4. Post-Deploy Setup

```bash
./scripts/setup-keda.sh                    # Scale-to-zero
./scripts/setup-cognito.sh                 # Auth configuration
./scripts/setup-pvc-backup.sh              # Daily PVC backups
./scripts/setup-image-update.sh            # Auto image updates
./scripts/setup-usage-tracking.sh          # Usage dashboard
./scripts/setup-alerts.sh <email>          # SNS email alerts
```

#### 5. Create First Tenant

```bash
./scripts/create-tenant.sh alice --display-name "Alice" --emoji "robot"
```

#### 6. Finalize

```bash
./scripts/post-deploy.sh          # CloudFront #2 + Route53 + WAF->ALB
./scripts/deploy-auth-ui.sh       # Upload auth UI to S3
```

## Tenant Management

```bash
./scripts/create-tenant.sh <name> [options]    # Create
./scripts/delete-tenant.sh <name>              # Delete (with confirmation)
./scripts/verify-tenant.sh <name>              # Health check
./scripts/check-all-tenants.sh                 # Check all tenants
./scripts/backup-tenant.sh <name> <bucket>     # Backup to S3
./scripts/restore-tenant.sh <name> <s3-path>   # Restore from S3
./scripts/admin-list-tenants.sh                # List tenants + cost
```

## Security

| Layer | Control |
|-------|--------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | Cloudflare Turnstile CAPTCHA + email domain restriction |
| Network | Internet-facing ALB with CF-only SG (pl-82a045eb) + WAF + HTTPS |
| Auth | Cognito signup + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef -- fetched on-demand, never persisted |
| LLM | Bedrock via Pod Identity -- zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero; daily EBS snapshots |
| Audit | CloudTrail + S3 + Athena + EKS control plane logging |

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

| Doc | Description |
|-----|-------------|
| [Architecture](docs/architecture.md) | Operator + ArgoCD flow, tenant lifecycle |
| [Security](docs/security.md) | 10-layer security model |
| [EKS Cluster](docs/components/eks-cluster.md) | Cluster, nodegroups, Karpenter, add-ons |
| [Networking](docs/components/networking.md) | VPC, CloudFront, ALB, WAF |
| [Auth](docs/components/auth.md) | Cognito, custom UI, Lambda triggers |
| [Scaling](docs/components/scaling.md) | KEDA scale-to-zero, cold start |
| [GitOps](docs/components/gitops.md) | ArgoCD manages tenant resources via Helm chart |
| [Admin Guide](docs/operations/admin-guide.md) | Deploy, manage, monitor |
| [User Guide](docs/operations/user-guide.md) | Signup, login, daily use |

## Project Structure

```
+-- auth-ui/                    # Custom login/signup (S3 + CloudFront)
+-- cdk/                        # AWS CDK infrastructure (TypeScript)
|   +-- lib/eks-cluster-stack.ts
|   +-- lambda/                 # Pre-signup, Post-confirmation, Cost-enforcer
|   +-- cdk.json.example        # Config template
+-- helm/                       # Helm chart (source of truth, synced by ArgoCD)
|   +-- charts/openclaw-platform/  # Tenant K8s resources (Deployment, Service, etc.)
|   +-- gateway.yaml            # Gateway API resource
|   +-- tenants/values-template.yaml  # Example values
+-- operator/                   # Tenant Operator (Rust/kube-rs)
|   +-- src/                    # Creates NS/PVC/SA + ArgoCD Application + KEDA HSO
|   +-- yaml/                   # CRD manifest, operator deployment
+-- docs/                       # Architecture, security, components, operations
+-- scripts/                    # 20+ operations scripts
+-- .github/workflows/ci.yml   # CI pipeline
```

## Cleanup

```bash
# 1. Delete all tenants
for tenant in $(kubectl get tenants -o jsonpath='{.items[*].metadata.name}'); do
  ./scripts/delete-tenant.sh "$tenant" --yes
done

# 2. Delete CloudFront #2 + Route53 records (created by post-deploy.sh, not CDK-managed)

# 3. Destroy CDK stack
cd cdk && npx cdk destroy OpenClawEksStack

# 4. Clean up orphan resources
./scripts/cleanup-test-resources.sh
```

## Upgrading

After pulling new changes (`git pull`), update the deployed components:

```bash
# 1. Infrastructure + Lambda code + Auth UI (CDK deploys all three)
cd cdk && npx cdk deploy OpenClawEksStack

# 2. Tenant Operator (rebuild + push + restart)
bash scripts/build-operator.sh

# 3. Auth UI (if you use deploy-auth-ui.sh instead of CDK BucketDeployment)
bash scripts/deploy-auth-ui.sh
```

Not all steps are needed for every update. Check the release notes for which components changed.

## Contributing

Contributions welcome. Please open an issue first to discuss changes.

## License

[MIT](LICENSE)

---

<p align="center">
  Built with love on <a href="https://aws.amazon.com/eks/">Amazon EKS</a> + <a href="https://aws.amazon.com/bedrock/">Amazon Bedrock</a>
</p>
