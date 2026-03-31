# OpenClaw Platform Architecture

> Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated workspace powered by Amazon Bedrock.

## Overview

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

Path-based routing via Gateway API: `claw.example.com/t/<tenant>/` -- one domain, one ALB, no wildcard DNS needed.

## Tenant Lifecycle

```
Cognito SignUp
  -> Pre-signup Lambda (email domain gate)
  -> Post-confirmation Lambda (creates Tenant CR)
  -> Operator reconciles via SSA:
       1. Namespace (openclaw-{tenant})
       2. PVC (10Gi gp3)
       3. ServiceAccount (Pod Identity)
       4. ArgoCD Application (points to helm/charts/openclaw-platform, auto-sync prune+selfHeal)
       5. KEDA HTTPScaledObject (15min idle -> 0)
  -> ArgoCD detects Application, syncs Helm chart:
       Deployment, Service, ConfigMap, NetworkPolicy,
       ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration
  -> Pod ready, HTTPRoute active, scale-to-zero armed
```

## Operator + ArgoCD Split

The Tenant Operator (Rust/kube-rs) creates 5 bootstrap resources via Server-Side Apply, then delegates workload resources to ArgoCD + Helm.

```
Tenant CR
  |
  v
Operator (SSA)                    ArgoCD (Helm sync)
  |                                 |
  +-- Namespace                     +-- Deployment
  +-- PVC                           +-- Service
  +-- ServiceAccount                +-- ConfigMap
  +-- ArgoCD Application ---------> +-- NetworkPolicy
  +-- KEDA HSO                      +-- ResourceQuota
                                    +-- PDB
                                    +-- HTTPRoute
                                    +-- TargetGroupConfiguration
```

The ArgoCD Application is created with `fullnameOverride={tenant}`, auto-sync enabled (prune + selfHeal), pointing to `helm/charts/openclaw-platform`.

**Cleanup:** On Tenant CR deletion, the operator deletes the namespace. Kubernetes cascades all resources inside. The ArgoCD Application is also deleted, stopping sync.

## EKS Cluster

```
EKS Cluster (v1.35)
|  Managed Node Group (Graviton ARM64 t4g.medium) + Karpenter (arm64 spot)
|  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   +-- Operator: Namespace, PVC, ServiceAccount, KEDA HSO
|   +-- ArgoCD/Helm: Deployment, Service, ConfigMap, HTTPRoute,
|       TargetGroupConfiguration, NetworkPolicy, ResourceQuota, PDB
|
+-- namespace: openclaw-system
|   +-- Tenant Operator (Rust/kube-rs)
|
+-- namespace: argocd
|   +-- ArgoCD (EKS add-on)
|   +-- ArgoCD Application per tenant
```

## Key Components

| Component | Technology | Purpose |
|-----------|-----------|--------|
| Infrastructure | AWS CDK (TypeScript) | VPC, EKS, IAM, Lambda, S3, CloudFront, WAF |
| Operator | Rust / kube-rs (SSA) | Creates NS/PVC/SA + ArgoCD Application + KEDA HSO |
| Helm chart | ArgoCD-synced | Source of truth for tenant workload resources |
| Auth | Cognito + custom UI | Signup, login, email domain gate |
| Scaling | KEDA HTTP Add-on | Scale-to-zero (15min idle) |
| LLM | Amazon Bedrock | Model access via Pod Identity (zero API keys) |
| Secrets | exec SecretRef | aws-sm provider, fetched on-demand, never persisted |
| Observability | CloudWatch Container Insights | Metrics, logs, alarms |

## Status Conditions

The operator updates `Tenant.status.conditions` during reconciliation:

| Condition | Meaning |
|-----------|---------|
| `NamespaceReady` | Namespace exists and is active |
| `PVCBound` | PVC is bound to a volume |
| `ArgoAppReady` | ArgoCD Application is synced and healthy |
| `KEDAReady` | HTTPScaledObject is active |

`Tenant.status.phase`: `Ready` (all conditions true) or `Suspended` (tenant disabled).

## Security Layers

| Layer | Control |
|-------|--------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | Cloudflare Turnstile CAPTCHA + email domain restriction |
| Network | Internet-facing ALB with CF-only SG (pl-82a045eb) + WAF + HTTPS |
| Auth | Cognito + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef -- fetched on-demand via aws-sm provider |
| LLM | Bedrock via Pod Identity -- zero API keys |
| Cost | Per-tenant monthly budget with per-model pricing |
| Data | PVC persists across scale-to-zero; daily EBS snapshots |
| Audit | CloudTrail + S3 + Athena + EKS control plane logging |

## Data Flow

```
User Request:
  Browser -> CloudFront #2 -> ALB (CF-only SG) -> HTTPRoute -> Pod
  Pod -> Bedrock (via Pod Identity, cross-region inference profiles)

Tenant Provisioning:
  Cognito SignUp -> Pre-signup Lambda (email gate)
  Cognito Confirm -> Post-confirmation Lambda -> Tenant CR
  Operator (SSA) -> Namespace + PVC + SA + ArgoCD App + KEDA HSO
  ArgoCD -> Helm sync -> Deployment + Service + ConfigMap + HTTPRoute
            + TGC + NetworkPolicy + ResourceQuota + PDB
```

## Related Docs

- [Security Deep Dive](security.md)
- [GitOps (ArgoCD)](components/gitops.md)
- [Component docs](components/)
- [Operations guides](operations/)
