# Tenant CRD + Operator Design

> Status: **Design Document** — not yet implemented.

## Overview

Replace the current Lambda-based tenant provisioning with a Kubernetes-native Tenant Custom Resource Definition (CRD) and a reconciliation operator. A `Tenant` CR becomes the single source of truth for each tenant's desired state; the operator watches these CRs and converges the cluster to match.

This approach also opens the door to replacing ArgoCD ApplicationSet generators — the operator can directly manage per-tenant resources without an intermediate GitOps layer.

## CRD Spec

```yaml
apiVersion: openclaw.io/v1alpha1
kind: Tenant
metadata:
  name: alice
spec:
  email: alice@example.com
  displayName: Alice
  emoji: "🐱"
  skills:
    - content-draft
    - social-intel
    - weather
  budget:
    monthlyUSD: 50
  enabled: true
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `email` | string | yes | Tenant email, must be unique across the cluster |
| `displayName` | string | yes | Human-readable name |
| `emoji` | string | no | Emoji identifier for dashboards / logs |
| `skills` | []string | no | List of enabled skill names |
| `budget.monthlyUSD` | int | no | Monthly spend cap in USD (enforced by usage-tracking) |
| `enabled` | bool | yes | `false` suspends the tenant (scales pod to 0, blocks ingress) |

### Status Subresource

```yaml
status:
  phase: Ready          # Pending | Provisioning | Ready | Suspended | Error
  conditions:
    - type: NamespaceReady
      status: "True"
    - type: PVCBound
      status: "True"
    - type: IngressReady
      status: "True"
    - type: KEDAReady
      status: "True"
    - type: NetworkPolicyApplied
      status: "True"
  lastReconcileTime: "2025-07-14T03:00:00Z"
```

## Operator Reconcile Loop

```
Watch Tenant CR
       │
       ▼
┌─────────────────────────────────────────────────┐
│  For each Tenant CR (create / update / delete): │
│                                                 │
│  1. Namespace     — ensure ns `tenant-{name}`   │
│  2. PVC           — 10Gi gp3 in the namespace   │
│  3. ServiceAccount— with Pod Identity annotation │
│  4. Ingress       — `{name}.your-domain.com`    │
│  5. HTTPScaledObject (KEDA) — scale-to-zero     │
│  6. NetworkPolicy — deny all except ALB + DNS   │
│  7. Secrets       — sync from Secrets Manager   │
│  8. Helm Release  — deploy openclaw-helm chart  │
│                                                 │
│  If enabled=false:                              │
│    → Scale deployment to 0                      │
│    → Remove Ingress rule                        │
│                                                 │
│  On delete:                                     │
│    → Finalizer cleans up all owned resources    │
│    → PVC deletion is configurable (retain/del)  │
└─────────────────────────────────────────────────┘
       │
       ▼
  Update status subresource
```

### Reconcile Triggers

- Tenant CR created / updated / deleted
- Owned resource drifts (operator re-converges)
- Periodic resync (default: 10 minutes)

### Error Handling

- Exponential backoff on transient failures (e.g., API server unavailable)
- Permanent errors (e.g., invalid email) set `phase: Error` with a descriptive condition message
- The operator never deletes a PVC on error — data safety first

## Relationship with ArgoCD ApplicationSet

Currently, ArgoCD ApplicationSet generates one `Application` per tenant using a Git generator or list generator. With the Tenant CRD:

| Aspect | ApplicationSet | Tenant CRD Operator |
|--------|---------------|---------------------|
| Source of truth | Git repo (values files) | Kubernetes CR |
| Provisioning | ArgoCD syncs Helm release | Operator creates resources directly |
| Scale-to-zero | Separate KEDA config | Operator manages HTTPScaledObject |
| Namespace lifecycle | Manual or separate automation | Operator owns namespace |
| Drift detection | ArgoCD diff | Operator watch + periodic resync |

**Migration path**: The Tenant CRD can fully replace ApplicationSet. During transition, both can coexist — the operator skips resources that ArgoCD still owns (detected via `app.kubernetes.io/managed-by` label).

## Implementation Recommendations

### Framework: Kubebuilder (preferred)

- Generates CRD manifests, RBAC, and controller scaffolding
- Native Go, minimal dependencies
- Well-documented for multi-group APIs

```bash
kubebuilder init --domain openclaw.io --repo github.com/openclaw/tenant-operator
kubebuilder create api --group tenant --version v1alpha1 --kind Tenant
```

### Alternative: Operator SDK

- Built on top of Kubebuilder, adds OLM integration
- Useful if distributing via OperatorHub is a goal
- Also supports Ansible/Helm-based operators (not recommended here — Go gives full control)

### Key Implementation Notes

- Use **controller-runtime's `controllerutil.SetControllerReference`** so owned resources are garbage-collected on Tenant deletion
- Add a **finalizer** for cleanup that requires external calls (e.g., removing Cognito user, cleaning up S3 data)
- Use **server-side apply** for owned resources to avoid conflicts with other controllers
- Emit **Kubernetes Events** on reconcile success/failure for observability

## Open Questions

1. Should `skills[]` be validated against a known registry, or is it free-form?
2. PVC retention policy on tenant deletion — default retain or delete?
3. Should the operator also manage the Cognito user pool entry, or leave that to the existing Lambda?
4. Budget enforcement — operator just stores the value, or actively enforces via admission webhook?
