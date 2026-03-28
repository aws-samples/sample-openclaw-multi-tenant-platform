# Automatic Image Update Strategy

## Problem

Upgrading OpenClaw requires updating the image tag in `values.yaml` and running `helm upgrade` for every tenant namespace. With many tenants, this is error-prone and time-consuming.

## Options Evaluated

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **A: Flux Image Automation** | Flux image reflector detects new tags, auto-creates PR | GitOps native; reviewable PRs | Requires full Flux stack (4 controllers) |
| **B: ArgoCD Image Updater** | ArgoCD plugin, annotation-based | Lightweight sidecar | Requires ArgoCD |
| **C: CronJob + kubectl** | K8s CronJob checks registry, runs `kubectl set image` | Zero dependencies; simple | Not GitOps; values.yaml not updated |
| **D: GitHub Actions** | CI workflow triggers `helm upgrade` | Audit trail in CI | Needs kubeconfig access |

## Chosen: Option C (CronJob + kubectl)

For a platform with a single admin, a simple CronJob is the most practical approach. It has zero additional infrastructure dependencies and is easy to debug.

## How It Works

1. CronJob runs every 6 hours in `kube-system` namespace
2. Queries GHCR API for the latest image tag
3. Compares with the current tag running in tenant deployments
4. If different, runs `kubectl set image` across all tenant namespaces
5. Logs the update for audit

## Installation

```bash
# Apply the CronJob manifest
./scripts/setup-image-update.sh

# Manual trigger
kubectl create job --from=cronjob/openclaw-image-updater manual-update -n kube-system
```

## CronJob Details

- **Schedule:** `0 */6 * * *` (every 6 hours)
- **Image:** `bitnami/kubectl:latest`
- **Registry check:** Uses `wget` to query GHCR tags API
- **Update method:** `kubectl set image` with label selector across all namespaces
- **RBAC:** ClusterRole with `get`, `list`, `patch` on Deployments

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Breaking change in new version | Filter to only patch versions (e.g., `2026.3.x`) |
| Registry unreachable | CronJob exits gracefully, retries next cycle |
| Rollout failure | Kubernetes rollout strategy handles failed pods |
| Image pull failure | Pod stays on old image; `kubectl rollout undo` available |

## Notes

- This CronJob updates the running deployments but does NOT update `values.yaml` in git
- For GitOps consistency, consider switching to Flux or ArgoCD when the platform grows beyond 100 tenants
- The CronJob manifest is at `scripts/image-update-cronjob.yaml`
