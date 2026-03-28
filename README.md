# OpenClaw Multi-Tenant Platform on EKS

Deploy isolated OpenClaw instances on Amazon EKS — one per user, fully separated.

## Architecture

```
EKS Cluster (CDK, us-west-2)
│  Managed Node Group + Karpenter
│  Add-ons: ALB Controller, EBS CSI, Pod Identity Agent
│
├── namespace: openclaw-{tenant}
│   ├── ServiceAccount + Pod Identity → shared IAM Role (ABAC)
│   ├── Deployment (OpenClaw Gateway)
│   │   ├── init-config (openclaw.json)
│   │   ├── init-skills (clawhub install)
│   │   ├── init-tools (fetch-secret.mjs + AWS SDK)
│   │   └── main (gateway, bind 127.0.0.1)
│   ├── ConfigMap (openclaw.json with exec SecretRef)
│   ├── PVC (gp3, 10Gi)
│   ├── Service (ClusterIP)
│   ├── Ingress (ALB IngressGroup, host-based routing)
│   ├── NetworkPolicy (deny cross-namespace)
│   └── ResourceQuota
```

## Security Design

1. **Namespace isolation** — each tenant runs in its own namespace
2. **Pod Identity ABAC** — shared IAM Role with session tags; each tenant can only access its own Secrets Manager secrets (`tenant-namespace` tag match)
3. **Exec SecretRef** — secrets fetched on-demand via exec provider, never persisted in env vars or filesystem
4. **NetworkPolicy** — deny all ingress from other tenant namespaces
5. **ResourceQuota** — CPU/memory/pod limits per tenant
6. **Non-root container** — OpenClaw runs as UID 1000
7. **Zero API keys for LLM** — Bedrock uses Pod Identity credential chain

## Prerequisites

- AWS CLI v2 + configured profile with EKS/EC2/IAM permissions
- AWS CDK v2 (`npm install -g aws-cdk`)
- kubectl
- Helm 3
- Node.js 18+

## Quick Start

```bash
# 1. Deploy EKS cluster (~15-20 min)
cd cdk && npx cdk deploy --profile <your-profile> --region us-west-2

# 2. Configure kubectl
aws eks update-kubeconfig --region us-west-2 --name openclaw-cluster --profile <your-profile>

# 3. Create a tenant
export OPENCLAW_TENANT_ROLE_ARN="<TenantRoleArn from CDK output>"
./scripts/create-tenant.sh alice

# 4. Verify
./scripts/verify-tenant.sh alice

# 5. Create more tenants
./scripts/create-tenant.sh bob
./scripts/create-tenant.sh carol

# 6. Verify isolation
./scripts/verify-tenant.sh alice bob
```

## Tenant Management

```bash
# Create
./scripts/create-tenant.sh <name>

# Delete
./scripts/delete-tenant.sh <name>

# Verify (single tenant)
./scripts/verify-tenant.sh <name>

# Verify with isolation check (two tenants)
./scripts/verify-tenant.sh <name-a> <name-b>
```

## Cost Estimate (3 tenants)

| Resource | Monthly Cost |
|----------|-------------|
| EKS control plane | ~$73 |
| EC2 (2x t3.medium on-demand) | ~$60 |
| EBS (3x 10Gi gp3) | ~$2.40 |
| ALB | ~$16 |
| NAT Gateway | ~$32 |
| Bedrock (usage-based) | varies |
| **Total (infra only)** | **~$184/mo** |

## Project Structure

```
├── cdk/                    # CDK stack (EKS + Karpenter + IAM)
├── helm/charts/            # Extended OpenClaw Helm chart
├── scripts/                # Tenant provisioning & verification
└── README.md
```

## Based On

- [thepagent/openclaw-helm](https://github.com/thepagent/openclaw-helm) — slim Helm chart (no Chromium)
- [AWS EKS Best Practices - Pod Identity ABAC](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS EKS Best Practices - Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)
