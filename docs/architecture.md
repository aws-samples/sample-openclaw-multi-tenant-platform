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
Cognito SignUp -> Lambda (post-confirmation) -> Tenant CR
  -> Operator reconciles: Namespace, PVC, SA, Deployment, Service, ConfigMap,
    HTTPRoute, TargetGroupConfiguration, NetworkPolicy, ResourceQuota, PDB, KEDA HSO
  -> Pod + HTTPRoute + NetworkPolicy + scale-to-zero ready
```

## Tenant Operator -- How It Works

The Tenant Operator is a Rust controller built with [kube-rs](https://kube.rs/). It watches `Tenant` CRDs and uses **Server-Side Apply (SSA)** to create and reconcile all K8s resources directly -- no Helm, no GitOps layer for tenant provisioning.

```
+------------------------------------------------------------------+
|                    OPERATOR RECONCILE LOOP                        |
+------------------------------------------------------------------+

  Tenant CR created/updated
      |
      v
  +---------------------+
  |  Tenant Operator     |  (openclaw-system namespace)
  |  Rust / kube-rs      |
  |  watches: Tenant CRD |
  +---------+-----------+
            |
            |  Server-Side Apply (SSA)
            |  PatchParams::apply("tenant-operator").force()
            v
  +---------------------------------------------+
  |  For each Tenant, creates in order:         |
  |                                             |
  |  1. Namespace      (openclaw-{name})        |
  |  2. PVC            (10Gi gp3)               |
  |  3. ServiceAccount (Pod Identity)           |
  |  4. ConfigMap      (gateway config)         |
  |  5. Deployment     (OpenClaw container)     |
  |  6. Service        (ClusterIP)              |
  |  7. NetworkPolicy  (cross-tenant blocked)   |
  |  8. ResourceQuota  (cpu/mem/pods cap)       |
  |  9. PDB            (minAvailable: 1)        |
  | 10. HTTPRoute      (Gateway API routing)    |
  | 11. TargetGroupConfig (ALB health check)    |
  | 12. KEDA HSO       (scale-to-zero)          |
  +---------------------+-----------------------+
                        |
                        v
  +---------------------------------------------+
  |  Update Tenant CR status:                   |
  |    phase: Ready | Suspended                 |
  |    conditions: NamespaceReady, PVCBound,    |
  |      DeploymentAvailable, KEDAReady,        |
  |      HTTPRouteReady, TGCReady               |
  +---------------------+-----------------------+
                        |
                        |  Requeue every 5 min
                        |  (drift detection)
                        v
                   [next reconcile]
```

**Cleanup:** On Tenant CR deletion, the operator deletes the namespace -- Kubernetes cascades all resources inside. PVC retention is handled by StorageClass `reclaimPolicy`.

### Why Not Helm?

The `helm/` directory contains reference templates for documentation and manual debugging. The operator does **not** shell out to `helm install` -- it uses kube-rs SSA directly for:
- Atomic reconciliation (all-or-nothing per resource)
- Drift detection on every 5-minute requeue
- No external binary dependency in the operator container

## EKS Cluster

```
EKS Cluster (v1.35)
|  Managed Node Group (Graviton ARM64 t4g.medium) + Karpenter (arm64 spot)
|  Add-ons: ALB Controller, EBS CSI, Pod Identity, CloudWatch Insights
|  KEDA HTTP Add-on
|
+-- namespace: openclaw-{tenant}
|   +-- Deployment + Service + ConfigMap + PVC (persists across scale-to-zero)
|   +-- HTTPRoute + TargetGroupConfiguration (Gateway API, path-based routing)
|   +-- HTTPScaledObject (KEDA, 15min idle -> 0)
|   +-- NetworkPolicy (cross-tenant blocked)
|   +-- ResourceQuota + PodDisruptionBudget
|   +-- ServiceAccount (Pod Identity -> shared TenantRole)
|
+-- namespace: openclaw-system
|   +-- Tenant Operator (Rust/kube-rs)
|
+-- namespace: karpenter
|   +-- Karpenter controller
|
+-- namespace: kube-system
    +-- ALB Controller, EBS CSI, CoreDNS, VPC CNI
```

## Key Components

| Component | Technology | Purpose |
|-----------|-----------|--------|
| Infrastructure | AWS CDK (TypeScript) | VPC, EKS, IAM, Lambda, S3, CloudFront, WAF |
| Operator | Rust / kube-rs (SSA) | Tenant CR -> all K8s resources directly |
| Helm chart | Reference only | Templates for documentation and manual debugging |
| Auth | Cognito + custom UI | Signup, login, email domain gate |
| Scaling | KEDA HTTP Add-on | Scale-to-zero (15min idle) |
| LLM | Amazon Bedrock | Model access via Pod Identity (zero API keys) |
| GitOps | ArgoCD (EKS Capability) | Platform components only (KEDA, monitoring) |
| Observability | CloudWatch Container Insights | Metrics, logs, alarms |

## Security Layers

| Layer | Control |
|-------|--------|
| Edge | CloudFront + WAF (AWS Common Rules + rate limit) |
| Signup | Cloudflare Turnstile CAPTCHA + email domain restriction |
| Network | Internet-facing ALB with CF-only SG + WAF + HTTPS |
| Auth | Cognito + local token auth + 3-layer origin protection |
| Tenant | Namespace isolation + NetworkPolicy + ABAC |
| Secrets | exec SecretRef -- fetched on-demand, never persisted |
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
  Operator (SSA) -> Namespace + PVC + SA + Pod Identity + Deployment + Service
                 + ConfigMap + HTTPRoute + TGC + NetworkPolicy + ResourceQuota
                 + PDB + KEDA HSO
```

## Deployment

See [README.md](../README.md) for quick start (`./setup.sh`) and step-by-step instructions.

## Related Docs

- [Security Deep Dive](security.md)
- [GitOps (ArgoCD)](components/gitops.md) -- platform components only, not tenant provisioning
- [Component docs](components/)
- [Operations guides](operations/)
