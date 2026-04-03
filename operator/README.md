# Tenant Operator

Kubernetes Operator (Rust/kube-rs) that manages the lifecycle of OpenClaw tenants. Creates 3 bootstrap resources per tenant via Server-Side Apply, then delegates workload management to ArgoCD + Helm.

> **Design decision**: see [ADR-002](../docs/adr.md) for why Operator + ArgoCD instead of pure Helm or Lambda-only.

## What It Does

```
Tenant CR (created by PostConfirmation Lambda or manually)
  │
  ▼
Operator reconcile loop (SSA)
  │
  ├── 1. ensure_namespace     → Namespace (openclaw-{tenant})
  ├── 2. ensure_argocd_app    → ArgoCD Application (tenant-{name} in argocd ns)
  │                              - Points to helm/charts/openclaw-platform
  │                              - Injects per-tenant Helm values
  │                              - Auto-sync with prune + selfHeal
  └── 3. ensure_reference_grant → ReferenceGrant (in keda ns, if scale-to-zero)
                                  + Interceptor TargetGroupConfiguration
  │
  ▼
ArgoCD syncs Helm chart → Deployment, Service, ConfigMap, NetworkPolicy, etc.
```

## Status Phases

| Phase | Condition | Meaning |
|-------|-----------|---------|
| `Provisioning` | ArgoCD not synced or Deployment not ready | Tenant is being set up |
| `Ready` | ArgoCD synced + Deployment available | Tenant is operational |
| `Suspended` | `spec.enabled: false` | Tenant disabled by admin |
| `Error` | `ReconcileError` condition | Reconcile failed (check condition message) |

Phase logic (from `controller.rs`):
```
if !enabled        → Suspended
if argocd && deploy → Ready
else               → Provisioning
```

On error, `apply()` wraps `apply_inner()` and writes `phase: Error` with the error message in conditions.

## CRD Reference

```yaml
apiVersion: openclaw.io/v1alpha1
kind: Tenant
```

### Spec Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `email` | string | ✅ | — | Workspace owner email |
| `displayName` | string | ✅ | — | Human-readable name |
| `emoji` | string | — | `null` | Emoji for dashboards |
| `skills` | string[] | — | `[]` | Enabled skill packages |
| `budget.monthlyUSD` | int | — | `100` | Monthly spend cap in USD |
| `enabled` | bool | — | `true` | Set false to suspend tenant |
| `image.repository` | string | — | chart default | Container image override |
| `image.tag` | string | — | Chart.AppVersion | Image tag override |
| `image.pullPolicy` | string | — | `IfNotPresent` | Pull policy |
| `resources.requests.cpu` | string | — | chart default | CPU request |
| `resources.requests.memory` | string | — | chart default | Memory request |
| `resources.limits.cpu` | string | — | chart default | CPU limit |
| `resources.limits.memory` | string | — | chart default | Memory limit |
| `env` | map | — | `null` | Extra environment variables |
| `alwaysOn` | bool | — | `false` | Skip scale-to-zero |

### Status Fields

| Field | Description |
|-------|-------------|
| `phase` | Current phase (see table above) |
| `conditions[]` | K8s-style conditions: `NamespaceReady`, `ArgocdAppReady`, `ReferenceGrantReady`, `ArgocdSynced`, `DeploymentAvailable`, `ReconcileError` |

## Environment Variables

Set via `build-operator.sh` (sed substitution from `cdk.json`):

| Variable | Purpose | Source |
|----------|---------|--------|
| `AWS_REGION` | AWS region for API calls | `cdk.json` context |
| `GATEWAY_DOMAIN` | Tenant URL domain (e.g. `claw.example.com`) | `cdk.json` `zoneName` |
| `COGNITO_POOL_ARN` | Cognito User Pool ARN for Helm values | `cdk.json` `cognitoPoolId` + account |
| `COGNITO_CLIENT_ID` | Cognito App Client ID | `cdk.json` `cognitoClientId` |
| `COGNITO_DOMAIN` | Cognito hosted UI domain | `cdk.json` `cognitoDomain` |
| `HELM_REPO_URL` | Git repo URL for ArgoCD Application source | `cdk.json` `githubOwner` + `githubRepo` |
| `HELM_TARGET_REVISION` | Git branch/tag for ArgoCD | Default: `main` |

All env vars have placeholder defense: `env_or_default()` rejects known CDK placeholder values (e.g. `REGION`, `COGNITO_POOL_ARN`) and falls back to defaults.

## Development

```bash
# Build + test
cd operator
cargo fmt --check
cargo clippy -- -D warnings
cargo test --lib

# Generate CRD YAML (after changing types.rs)
cargo run --bin crdgen > yaml/crd.yaml

# Build + deploy (injects env vars + applies CRD + deployment + gateway)
bash scripts/build-operator.sh
```

The Operator image is automatically built by GitHub Actions (`operator-build.yml`) on push to main when `operator/**` files change. Multi-arch (amd64 + arm64) images are published to GHCR.

## How to Extend

To add a new per-tenant resource managed by the Operator (not Helm):

1. Add a new `ensure_*` function in `resources.rs`
2. Call it from `apply_inner()` in `controller.rs`
3. Add a condition to track its status
4. Add RBAC permissions in `deployment.yaml` if needed
5. Add cleanup in the finalizer (`cleanup()` in `controller.rs`)

To add a new per-tenant resource managed by Helm (recommended for most cases):

1. Add a new template in `helm/charts/openclaw-platform/templates/`
2. Add values in `values.yaml`
3. ArgoCD auto-syncs — no Operator changes needed
