# ApplicationSet

## Role in the Architecture

The platform uses a 3-layer model for tenant management:

```
Layer 1: ApplicationSet (ArgoCD)  → Generates per-tenant Applications from list elements
Layer 2: ArgoCD (EKS add-on)         → GitOps: syncs Helm chart, drift detection, self-heal
Layer 3: Helm chart                   → Workload: Deployment, Service, ConfigMap, NetworkPolicy, etc.
```

> **Note**: The Operator was replaced by ArgoCD ApplicationSet in PR #273. This section is kept for historical context.

The Operator was intentionally thin (~400 lines of logic in `resources.rs` + `controller.rs`). It only creates the "envelope" (namespace + ArgoCD pointer), then ArgoCD + Helm handle everything inside.

### Why Not Lambda-Only?

The PostConfirmation Lambda could create all resources directly, but:

- **No reconcile loop**: Lambda is fire-and-forget. If a resource is accidentally deleted, nothing recreates it
- **No drift detection**: without ArgoCD, manual changes persist
- **No declarative state**: `kubectl get applications -n argocd -l openclaw.io/tenant` gives a single view of all tenants with their phase

### Why Not Operator-Creates-Everything?

The Operator could create Deployments, Services, etc. directly, but:

- **Duplicates Helm**: every resource would need separate management
- **No GitOps**: changes require Operator redeployment, not just a git push
- **800+ lines**: vs ~400 lines with the ArgoCD delegation model

## Server-Side Apply (SSA)

The Operator uses [Server-Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/) with field manager `applicationset` and `force: true`.

SSA advantages over `kubectl apply`:
- **Create-or-update** in a single API call (no "get then create/patch" race)
- **Field ownership tracking**: K8s knows which fields the Operator owns vs ArgoCD vs manual edits
- **Conflict resolution**: `force: true` means the Operator always wins for its fields

## Reconcile Loop

```
Watch: ApplicationSet elements in openclaw-system namespace
  │
  ▼
For each ApplicationSet element change:
  │
  ├── apply_inner():
  │   ├── ensure_namespace (SSA)
  │   ├── ensure_argocd_app (SSA) → generates Helm values from TenantSpec
  │   ├── ensure_reference_grant (SSA, if scale-to-zero)
  │   ├── check_argocd_sync → is ArgoCD Application synced + healthy?
  │   ├── check_deployment → is Deployment available?
  │   └── patch_status → phase + conditions
  │
  ├── On success:
  │   ├── phase = Ready (if ArgoCD synced + Deployment available)
  │   ├── phase = Provisioning (if not yet ready)
  │   ├── phase = Suspended (if spec.enabled = false)
  │   └── requeue: 300s (Ready) or 30s (Provisioning)
  │
  └── On error:
      ├── phase = Error + ReconcileError condition with message
      └── ArgoCD auto-retry
```

## Helm Values Generation

`ensure_argocd_app()` builds the Helm values passed to ArgoCD. Key mappings:

| TenantSpec field | Helm value | Effect |
|-----------------|------------|--------|
| `metadata.name` | `fullnameOverride`, `tenant.name` | All resource names = tenant name |
| `spec.email` | `tenant.email` | Stored in ConfigMap |
| `spec.enabled` | `tenant.enabled` | Controls Deployment replicas |
| `spec.budget` | `tenant.budget` | Cost-enforcer threshold |
| `spec.skills` | `skills` | Skill packages to install |
| `spec.alwaysOn` | `scaleToZero.enabled` (inverted) | Skip KEDA scale-to-zero |
| `spec.image.*` | `image.repository`, `image.tag`, `image.pullPolicy` | Per-tenant image override |
| env: `GATEWAY_DOMAIN` | `gateway.domain`, `ingress.host` | Tenant URL routing |
| env: `COGNITO_*` | `gateway.cognito.*` | Auth configuration |

## Scaling

- Single replica, no leader election needed
- One Operator manages all tenants (tested with 3 tenants, designed for hundreds)
- Reconcile is per-tenant, failures don't block other tenants
- Requeue interval: 30s (provisioning) / 300s (ready) — prevents API server overload

## Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/types.rs` | 130 | CRD definition (TenantSpec, TenantStatus, TenantImage) |
| `src/controller.rs` | 446 | Reconcile loop, phase logic, error handling, finalizer |
| `src/resources.rs` | 384 | ensure_namespace, ensure_argocd_app, ensure_reference_grant, env_or_default |
| `src/config.rs` | ~50 | Operator config from env vars |
| `src/webhook.rs` | 78 | Admission webhook (validation) |
| `src/metrics.rs` | ~30 | Prometheus metrics |
| `yaml/crd.yaml` | ~100 | Generated CRD manifest |
| `yaml/deployment.yaml` | ~120 | Operator Deployment + RBAC (contains placeholders) |
