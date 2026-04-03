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
  -> Post-confirmation Lambda (creates ApplicationSet element)
  -> ApplicationSet generates Applications via SSA:
       1. Namespace (openclaw-{tenant})
       2. ArgoCD Application (points to helm/charts/openclaw-platform, auto-sync prune+selfHeal)
       3. ReferenceGrant (in keda namespace, when scaleToZero enabled)
  -> ArgoCD detects Application, syncs Helm chart:
       PVC, ServiceAccount, Deployment, Service, ConfigMap, NetworkPolicy,
       ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration, KEDA HSO
  -> Pod ready, HTTPRoute active, scale-to-zero armed
```

## ApplicationSet + ArgoCD

The ArgoCD ApplicationSet generates per-tenant Applications. Each Application syncs the Helm chart with tenant-specific values.

```
ApplicationSet element
  |
  v
ApplicationSet (generator)        ArgoCD (Helm sync)
  |                                 |
  +-- Namespace                     +-- PVC
  +-- ArgoCD Application ---------> +-- ServiceAccount
  +-- ReferenceGrant (keda ns)      +-- Deployment
                                    +-- Service
                                    +-- ConfigMap
                                    +-- NetworkPolicy
                                    +-- ResourceQuota
                                    +-- PDB
                                    +-- HTTPRoute
                                    +-- TargetGroupConfiguration
                                    +-- KEDA HSO
```

The ArgoCD Application is created with `fullnameOverride={tenant}`, auto-sync enabled (prune + selfHeal), pointing to `helm/charts/openclaw-platform`.

**Cleanup:** On ApplicationSet element deletion, the operator deletes the ArgoCD Application, the ReferenceGrant (if exists), then the namespace. Kubernetes cascades all resources inside the namespace.

## EKS Cluster

```
EKS Cluster (v1.35)
|  Managed Node Group (Graviton ARM64 t4g.medium) + Karpenter (arm64 spot)
|  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   All managed by ArgoCD (Helm chart):
|     Namespace                      PVC (10Gi gp3)
|     ArgoCD Application            ServiceAccount (Pod Identity)
|     ReferenceGrant (in keda ns)   Deployment + Service + ConfigMap
|                                    HTTPRoute + TGC + NetworkPolicy
|                                    ResourceQuota + PDB + KEDA HSO
|
+-- namespace: openclaw-system
|   +-- ApplicationSet (ArgoCD generator)
|
+-- namespace: argocd
|   +-- ArgoCD (EKS add-on)
|   +-- ArgoCD Application per tenant
```

## Key Components

| Component | Technology | Purpose |
|-----------|-----------|--------|
| Infrastructure | AWS CDK (TypeScript) | VPC, EKS, IAM, Lambda, S3, CloudFront, WAF |
| ApplicationSet | ArgoCD generator | Generates per-tenant Applications from list elements |
| Helm chart | ArgoCD-synced | Source of truth for tenant workload resources |
| Auth | Cognito + custom UI | Signup, login, email domain gate |
| Scaling | KEDA HTTP Add-on | Scale-to-zero (15min idle) |
| LLM | Amazon Bedrock | Model access via Pod Identity (zero API keys) |
| Secrets | exec SecretRef | aws-sm provider, fetched on-demand, never persisted |
| Observability | CloudWatch Container Insights | Metrics, logs, alarms |

## Status Conditions

The operator updates `Tenant.status.conditions` during reconciliation:

| Condition | Meaning |
|-----------|--------|
| `NamespaceReady` | Namespace exists and is active |
| `ArgoSyncHealthy` | ArgoCD Application is synced and healthy |
| `DeploymentAvailable` | Tenant Deployment has available replicas |
| `ReferenceGrantReady` | ReferenceGrant created in keda namespace (when scaleToZero enabled) |
| `ReconcileError` | Set on reconcile failure with error message |

`Tenant.status.phase`: `Ready` (ArgoCD synced + Deployment available), `Provisioning` (in progress), `Suspended` (tenant disabled), or `Error` (reconcile failed).

## Security Layers

| Layer | Control |
|-------|--------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | WAF Bot Control (opt-in) + email domain restriction + rate limiting |
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
  Cognito Confirm -> Post-confirmation Lambda -> ApplicationSet element
  ApplicationSet -> per-tenant ArgoCD Application -> Helm chart sync
  ArgoCD -> Helm sync -> PVC + SA + Deployment + Service + ConfigMap
            + HTTPRoute + TGC + NetworkPolicy + ResourceQuota + PDB + KEDA HSO
```

## Related Docs

- [Security Deep Dive](security.md)
- [GitOps (ArgoCD)](components/gitops.md)
- [Component docs](components/)
- [Operations guides](operations/)
