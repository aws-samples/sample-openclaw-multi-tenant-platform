# OpenClaw Platform Architecture

> Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated workspace powered by Amazon Bedrock.

## Overview

```
Internet
  │
  ├─ your-domain.com ──► CloudFront #1 ──► S3 (custom auth UI)
  │
  ├─ claw.your-domain.com ──► CloudFront #2 ──► Internet-facing ALB ──► EKS Pod
  │                                               (CF-only SG + WAF)
  │
  └─ Outbound only: EKS Pod ──► NAT Gateway (HA) ──► Internet
```

Path-based routing via Gateway API: `claw.example.com/t/<tenant>/` — one domain, one ALB, no wildcard DNS needed.

## Tenant Lifecycle

```
Cognito SignUp → Lambda (post-confirmation) → Tenant CR
  → Operator reconciles: Namespace, PVC, SA, ArgoCD Application, KEDA HSO
  → ArgoCD syncs Helm chart into tenant namespace
  → Pod + HTTPRoute + NetworkPolicy + scale-to-zero ready
```

## EKS Cluster

```
EKS Cluster (v1.35)
│  Managed Node Group (Graviton ARM64 t4g.medium) + Karpenter (arm64 spot)
│  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
│  ArgoCD (EKS Capability) + KEDA HTTP Add-on
│
├── namespace: openclaw-{tenant}
│   ├── Deployment + PVC (persists across scale-to-zero)
│   ├── HTTPRoute (Gateway API, path-based routing)
│   ├── HTTPScaledObject (KEDA, 15min idle → 0)
│   ├── NetworkPolicy (cross-tenant blocked)
│   └── ResourceQuota
│
├── namespace: openclaw-system
│   └── Tenant Operator (Rust/kube-rs)
│
├── namespace: karpenter
│   └── Karpenter controller
│
└── namespace: kube-system
    └── ALB Controller, EBS CSI, CoreDNS, VPC CNI
```

## Key Components

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Infrastructure | AWS CDK (TypeScript) | VPC, EKS, IAM, Lambda, S3, CloudFront, WAF |
| Operator | Rust / kube-rs | Tenant CR → K8s primitives + ArgoCD Application |
| Auth | Cognito + custom UI | Signup, login, email domain gate |
| Scaling | KEDA HTTP Add-on | Scale-to-zero (15min idle) |
| GitOps | ArgoCD (EKS Capability) | Helm chart sync per tenant |
| LLM | Amazon Bedrock | Model access via Pod Identity (zero API keys) |
| Observability | CloudWatch Container Insights | Metrics, logs, alarms |

## Security Layers

| Layer | Control |
|-------|---------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | Cloudflare Turnstile CAPTCHA + email domain restriction |
| Network | Internet-facing ALB with CF-only SG + WAF + HTTPS |
| Auth | Cognito + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef — fetched on-demand, never persisted |
| LLM | Bedrock via Pod Identity — zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero; daily EBS snapshots |
| Audit | CloudTrail + S3 + Athena + EKS control plane logging |

## Data Flow

```
User Request:
  Browser → CloudFront #2 → ALB (CF-only SG) → HTTPRoute → Pod
  Pod → Bedrock (via Pod Identity, cross-region inference profiles)

Tenant Provisioning:
  Cognito SignUp → Pre-signup Lambda (email gate)
  Cognito Confirm → Post-confirmation Lambda → Tenant CR
  Operator → Namespace + PVC + SA + Pod Identity + ArgoCD App
  ArgoCD → Helm release in tenant namespace
```

## Deployment

See [README.md](../README.md) for quick start (`./setup.sh`) and step-by-step instructions.

## Related Docs

- [Security Deep Dive](security.md)
- [Component docs](components/)
- [Operations guides](operations/)
