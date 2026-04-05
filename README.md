<p align="center">
  <img src="https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-eks&logoColor=white" alt="EKS">
  <img src="https://img.shields.io/badge/AWS-CDK-FF9900?logo=amazon-aws&logoColor=white" alt="CDK">
  <img src="https://img.shields.io/badge/Bedrock-LLM-8B5CF6?logo=amazon-aws&logoColor=white" alt="Bedrock">
  <img src="https://img.shields.io/badge/KEDA-Scale--to--Zero-326CE5?logo=kubernetes&logoColor=white" alt="KEDA">
  <img src="https://img.shields.io/badge/License-MIT--0-green" alt="MIT-0">
  <img src="https://img.shields.io/badge/Status-Experimental-yellow" alt="Experimental">
</p>

# OpenClaw Platform

> Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated, private AI workspace powered by Amazon Bedrock -- zero API keys, zero shared data.

Deploy in 20 minutes. Scale to 500 users. Pay only for what you use.

> **Experimental** — This project is provided for experimentation and learning purposes only. It is **not intended for production use**. APIs, architecture, and configuration may change without notice. See [Security](docs/security.md) for details.

## Features

- **One tenant per user** -- isolated namespace, PVC, network policy, IAM role
- **Zero API keys** -- LLM access via Amazon Bedrock + Pod Identity
- **Scale to zero** -- KEDA scales idle pods to 0; cold start in 15-30s
- **3-layer origin protection** -- internet-facing ALB with CF-only SG + WAF + HTTPS
- **Custom auth UI** -- branded login/signup on your domain (no Cognito Hosted UI)
- **Self-service signup** -- Cognito + Lambda auto-provisions tenants
- **ArgoCD ApplicationSet managed** -- ApplicationSet generates per-tenant ArgoCD Applications; each syncs Helm chart with tenant-specific values ([details](docs/architecture.md))
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
|  Add-ons: ALB Controller, EBS CSI, EFS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   ApplicationSet-managed (ArgoCD):
|     Namespace                      PVC (EFS)
|     ArgoCD Application            ServiceAccount (Pod Identity)
|     ReferenceGrant (keda ns)      Deployment + Service + ConfigMap
|                                    HTTPRoute + TGC + NetworkPolicy + PDB + KEDA HSO
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
- kubectl + Helm 3, Node.js 22+
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
npx cdk deploy
```

Creates: EKS cluster, VPC, IAM roles, EFS, Lambda, S3, CloudFront, WAF, CloudWatch, SNS (~15-20 min).

#### 3. Setup ArgoCD

```bash
aws eks update-kubeconfig --region <region> --name openclaw-cluster
bash scripts/setup-argocd.sh
```

Installs ArgoCD via Helm. For production, consider EKS ArgoCD Capability (managed).

#### 4. Deploy Platform

```bash
bash scripts/deploy-platform.sh
```

`deploy-platform.sh` creates the `openclaw-system` namespace, injects values from `cdk/cdk.json` into the ApplicationSet and Gateway manifests, then applies them.


> **ECR Pull-Through Cache (optional)**: For production, you can enable ECR pull-through cache to avoid GHCR rate limits. Set `ghcrCredentialArn` in `cdk.json` -- see `cdk.json.example` for details.


#### 5. Post-Deploy Setup

```bash
./scripts/setup-keda.sh                    # Scale-to-zero
```

Cognito triggers, CloudWatch alarms, audit logging, and usage tracking are all managed by CDK -- no manual setup needed.

#### 6. Create First Tenant

```bash
./scripts/create-tenant.sh alice --email alice@example.com --display-name "Alice"
```

#### 7. Finalize

```bash
./scripts/post-deploy.sh          # CloudFront #2 + Route53 + WAF->ALB
```

> **Note**: Auth UI is deployed automatically by CDK (`BucketDeployment`). If you need to manually re-deploy or override config, run `./scripts/deploy-auth-ui.sh`.

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
| Signup | WAF Bot Control (opt-in) + email domain restriction + rate limiting |
| Network | Internet-facing ALB with CF-only SG (pl-82a045eb) + WAF + HTTPS |
| Auth | Cognito signup + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef -- fetched on-demand, never persisted |
| LLM | Bedrock via Pod Identity -- zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero (EFS, multi-AZ) |
| Audit | CloudTrail + S3 + Athena + EKS control plane logging |

## Cost

| Resource | 3 tenants | 100 tenants |
|----------|-----------|-------------|
| EKS control plane | ~$73 | ~$73 |
| EC2 (Graviton + Karpenter spot) | ~$48 | ~$48-150 |
| EFS (per actual usage) | ~$0.15 | ~$75 |
| ALB + NAT (x2) + CloudFront + WAF | ~$60 | ~$65 |
| CloudWatch + Lambda + S3 | ~$15 | ~$20 |
| Bedrock | varies | varies |
| **Total (infra)** | **~$198/mo** | **~$286-388/mo** |

> KEDA scale-to-zero active. EC2 scales with concurrent usage, not total tenants.

## Documentation

| Doc | Description |
|-----|-------------|
| [Architecture](docs/architecture.md) | ApplicationSet + ArgoCD flow, tenant lifecycle |
| [Security](docs/security.md) | 10-layer security model |
| [EKS Cluster](docs/components/eks-cluster.md) | Cluster, nodegroups, Karpenter, add-ons |
| [Networking](docs/components/networking.md) | VPC, CloudFront, ALB, WAF |
| [Auth](docs/components/auth.md) | Cognito, custom UI, Lambda triggers |
| [Scaling](docs/components/scaling.md) | KEDA scale-to-zero, cold start |
| [GitOps](docs/components/gitops.md) | ArgoCD manages tenant resources via Helm chart |
| [ApplicationSet](docs/components/applicationset.md) | Multi-tenant ArgoCD generator, tenant lifecycle |
| [Admin Guide](docs/operations/admin-guide.md) | Deploy, manage, monitor |
| [User Guide](docs/operations/user-guide.md) | Signup, login, daily use |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes |
| [ADRs](docs/adr.md) | Architecture decision records |

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
+-- helm/applicationset.yaml    # ArgoCD ApplicationSet (multi-tenant generator)
|   +-- src/                    # Creates Namespace + ArgoCD Application + ReferenceGrant
+-- docs/                       # Architecture, security, components, operations
+-- scripts/                    # 20+ operations scripts
+-- .github/workflows/ci.yml   # CI pipeline
```

## Cleanup

```bash
# 1. Delete all tenants
for tenant in $(kubectl get applicationset openclaw-tenants -n argocd -o jsonpath='{.spec.generators[0].list.elements[*].name}'); do
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

# 2. Re-apply platform manifests
bash scripts/deploy-platform.sh

# 3. Auth UI (if you use deploy-auth-ui.sh instead of CDK BucketDeployment)
bash scripts/deploy-auth-ui.sh
```

Not all steps are needed for every update. Check the release notes for which components changed.

## Contributing

Contributions welcome. Please open an issue first to discuss changes.

## License

[MIT-0](LICENSE)

---

<p align="center">
  Built with love on <a href="https://aws.amazon.com/eks/">Amazon EKS</a> + <a href="https://aws.amazon.com/bedrock/">Amazon Bedrock</a>
</p>
