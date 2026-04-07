<p align="center">
  <img src="https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-eks&logoColor=white" alt="Amazon EKS">
  <img src="https://img.shields.io/badge/AWS-CDK-FF9900?logo=amazon-aws&logoColor=white" alt="AWS CDK">
  <img src="https://img.shields.io/badge/Bedrock-LLM-8B5CF6?logo=amazon-aws&logoColor=white" alt="Amazon Bedrock">
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
- **3-layer origin protection** -- internet-facing ALB with CF-only SG + AWS WAF + HTTPS
- **Custom auth UI** -- branded login/signup on your domain (no Amazon Cognito Hosted UI)
- **Self-service signup** -- Amazon Cognito + AWS Lambda auto-provisions tenants
- **ArgoCD ApplicationSet managed** -- ApplicationSet generates per-tenant ArgoCD Applications; each syncs Helm chart with tenant-specific values ([details](docs/architecture.md))
- **Cost control** -- per-tenant monthly budget with per-model pricing alerts
- **Graviton ARM64** -- 20% cheaper compute with t4g instances

## Architecture

Path-based routing via Gateway API: `claw.example.com/t/<tenant>/` -- one domain, one ALB, no wildcard DNS needed.

```
Internet
  |
  +- claw.your-domain.com --> Amazon CloudFront (single distribution)
  |                            /        -> S3 (auth UI)           [CDK-managed]
  |                            /t/*     -> Internet-facing ALB    [post-deploy.sh]
  |                                        (CF-only SG + AWS WAF) -> Amazon EKS Pod
  +- Outbound only: Amazon EKS Pod --> NAT Gateway (HA) --> Internet
```

```
Amazon EKS Cluster
|  Managed Node Group (Graviton ARM64) + Karpenter (arm64 spot)
|  Add-ons: ALB Controller, EBS CSI, Amazon EFS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   ApplicationSet-managed (ArgoCD):
|     Namespace                      PVC (Amazon EFS)
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
- AWS CDK v2 (`npm install -g aws-cdk`), bootstrapped (`cdk bootstrap`)
- Docker (running — required for AWS CDK asset bundling)
- kubectl + Helm 3, Node.js 22+
- Route53 hosted zone + ACM certificates (deployment region + us-east-1)
- Amazon Cognito User Pool + App Client (**no client secret** -- public client for SPA)

#### 1. Configure

```bash
cp cdk/cdk.json.example cdk/cdk.json
# Edit cdk/cdk.json -- fill in context values (see cdk.json.example for full list)
```

#### 2. Deploy Infrastructure

```bash
cd cdk && npm install
cdk bootstrap  # Only needed once per account/region
n# Ensure your AWS CLI default region matches your target deployment region:
# aws configure get region   # should show your target region
npx cdk deploy
```

Creates: Amazon EKS cluster, VPC, IAM roles, Amazon EFS, AWS Lambda, Amazon S3, Amazon CloudFront, AWS WAF, CloudWatch, SNS (~15-20 min).

#### 3. Setup ArgoCD

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
bash scripts/setup-argocd.sh
```

Installs ArgoCD via Helm. For production, consider Amazon EKS ArgoCD Capability (managed).

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

Amazon Cognito triggers, CloudWatch alarms, audit logging, and usage tracking are all managed by AWS CDK -- no manual setup needed.

#### 6. Create First Tenant

```bash
./scripts/create-tenant.sh alice --email alice@example.com
```

#### 7. Finalize

```bash
./scripts/post-deploy.sh          # Add ALB origin to Amazon CloudFront + Route53 + AWS WAF
```

> **Note**: Auth UI is deployed automatically by AWS CDK (`BucketDeployment`). If you need to manually re-deploy or override config, run `./scripts/deploy-auth-ui.sh`.

## Tenant Management

```bash
./scripts/create-tenant.sh <name> [options]    # Create
./scripts/delete-tenant.sh <name>              # Delete (with confirmation)
./scripts/verify-tenant.sh <name>              # Health check
./scripts/check-all-tenants.sh                 # Check all tenants
./scripts/backup-tenant.sh <name> <bucket>     # Backup to Amazon S3
./scripts/restore-tenant.sh <name> <s3-path>   # Restore from Amazon S3
./scripts/admin-list-tenants.sh                # List tenants + cost
```

## Security

| Layer | Control |
|-------|--------|
| Edge | Amazon CloudFront + AWS WAF (AWS Common Rules + rate limit) |
| Signup | AWS WAF Bot Control (opt-in) + email domain restriction + rate limiting |
| Network | Internet-facing ALB with CF-only SG (pl-82a045eb) + AWS WAF + HTTPS |
| Auth | Amazon Cognito signup + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef -- fetched on-demand, never persisted |
| LLM | Amazon Bedrock via Pod Identity -- zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero (Amazon EFS, multi-AZ) |
| Audit | CloudTrail + Amazon S3 + Athena + Amazon EKS control plane logging |

## Cost

| Resource | 3 tenants | 100 tenants |
|----------|-----------|-------------|
| Amazon EKS control plane | ~$73 | ~$73 |
| EC2 (Graviton + Karpenter spot) | ~$48 | ~$48-150 |
| Amazon EFS (per actual usage) | ~$0.15 | ~$75 |
| ALB + NAT (x2) + Amazon CloudFront + AWS WAF | ~$60 | ~$65 |
| CloudWatch + AWS Lambda + Amazon S3 | ~$15 | ~$20 |
| Amazon Bedrock | varies | varies |
| **Total (infra)** | **~$198/mo** | **~$286-388/mo** |

> KEDA scale-to-zero active. EC2 scales with concurrent usage, not total tenants.

## Documentation

| Doc | Description |
|-----|-------------|
| [Architecture](docs/architecture.md) | ApplicationSet + ArgoCD flow, tenant lifecycle |
| [Security](docs/security.md) | 10-layer security model |
| [Amazon EKS Cluster](docs/components/eks-cluster.md) | Cluster, nodegroups, Karpenter, add-ons |
| [Networking](docs/components/networking.md) | VPC, Amazon CloudFront, ALB, AWS WAF |
| [Auth](docs/components/auth.md) | Amazon Cognito, custom UI, AWS Lambda triggers |
| [Scaling](docs/components/scaling.md) | KEDA scale-to-zero, cold start |
| [GitOps](docs/components/gitops.md) | ArgoCD + ApplicationSet, tenant lifecycle |
| [Admin Guide](docs/operations/admin-guide.md) | Deploy, manage, monitor |
| [User Guide](docs/operations/user-guide.md) | Signup, login, daily use |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes |

## Project Structure

```
+-- auth-ui/                    # Custom login/signup (Amazon S3 + Amazon CloudFront)
+-- cdk/                        # AWS CDK infrastructure (TypeScript)
|   +-- lib/eks-cluster-stack.ts
|   +-- lambda/                 # Pre-signup, Post-confirmation, Cost-enforcer
|   +-- cdk.json.example        # Config template
+-- helm/                       # Helm chart (source of truth, synced by ArgoCD)
|   +-- charts/openclaw-platform/  # Tenant K8s resources (Deployment, Service, etc.)
|   +-- gateway.yaml            # Gateway API resource
|   +-- tenants/values-template.yaml  # Example values
+-- helm/applicationset.yaml    # ArgoCD ApplicationSet (multi-tenant generator)
+-- docs/                       # Architecture, security, components, operations
+-- scripts/                    # 20+ operations scripts
+-- .github/workflows/ci.yml   # CI pipeline
```

## Cleanup

```bash
# 1. Delete all tenants
for tenant in $(kubectl get applicationset openclaw-tenants -n argocd -o jsonpath='{.spec.generators[0].list.elements[*].name}'); do
  ./scripts/delete-tenant.sh "$tenant" --force
done

# 2. Amazon CloudFront ALB origin and Route53 are cleaned up by cdk destroy

# 3. Destroy AWS CDK stack
cd cdk && npx cdk destroy OpenClawEksStack

# 4. Clean up retained resources (not deleted by AWS CDK — data protection)
./scripts/cleanup-test-resources.sh
```

> **Retained resources**: Amazon EFS file systems and Amazon S3 error-page buckets use `removalPolicy: RETAIN` to protect tenant data. After `cdk destroy`, these remain in your account. To fully clean up:
>
> ```bash
> # List retained Amazon EFS (check for tenant data before deleting)
> aws efs describe-file-systems --query 'FileSystems[?contains(Name,`TenantEfs`)].FileSystemId' --output text
>
> # List retained Amazon S3 buckets
> aws s3api list-buckets --query 'Buckets[?contains(Name,`openclaweks`)].Name' --output text
> ```
>
> Delete manually after confirming no data is needed.

## Upgrading

After pulling new changes (`git pull`), update the deployed components:

```bash
# 1. Infrastructure + AWS Lambda code + Auth UI (AWS CDK deploys all three)
cd cdk && npx cdk deploy OpenClawEksStack

# 2. Re-apply platform manifests
bash scripts/deploy-platform.sh

# 3. Auth UI (if you use deploy-auth-ui.sh instead of AWS CDK BucketDeployment)
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

---

Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

SPDX-License-Identifier: MIT-0
