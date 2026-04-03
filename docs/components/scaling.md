# Scale-to-Zero & Autoscaling

## Overview

Idle tenant pods scale to 0 replicas via KEDA HTTP Add-on. When an HTTP request arrives, the interceptor proxy holds it, triggers scale-up, and forwards once the pod is ready. PVC data survives scale-to-zero.

## How It Works

```
Client -> ALB -> KEDA HTTP Interceptor Proxy -> Pod (0->1)
                   (holds request if pod=0)       |
                                                  PVC (gp3 10Gi)
```

1. Pod running -> interceptor proxies directly to pod
2. Pod at 0 -> interceptor holds request -> triggers scale to 1
3. Pod starts (15-30s) -> interceptor forwards buffered request
4. Pod idle 15min -> KEDA scales back to 0

## HTTPScaledObject

The KEDA HTTPScaledObject is created by the Helm chart (`templates/httpscaledobject.yaml`), synced by ArgoCD. The Operator passes `scaleToZero` settings via the ArgoCD Application helm values.

The Helm chart also has a template (`httpscaledobject.yaml`) for `scaleToZero.enabled = true`, but for ArgoCD-managed tenants the Operator's HSO takes precedence.

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: {tenant}
spec:
  hosts:
    - {ingress.host}
  pathPrefixes:
    - /
  scaleTargetRef:
    name: {tenant}
    kind: Deployment
    apiVersion: apps/v1
    service: {tenant}
    port: 18789
  replicas:
    min: 0
    max: 1
  scalingMetric:
    requestRate:
      granularity: 1s
      targetValue: 1
      window: 900s  # 15 min idle timeout
```

**Constraints:**
- PVC is `ReadWriteOnce` -- only one pod can mount it -> `maxReplicas` must be 1
- HPA and HTTPScaledObject are mutually exclusive

## Cold Start

| Phase | Duration |
|-------|----------|
| Pod scheduling | ~2s |
| Image pull | ~5-15s (first time; cached after) |
| Init containers | ~10-17s |
| Gateway startup | ~3-5s |
| **Total (first)** | **~20-40s** |
| **Total (cached)** | **~15-20s** |

During cold start, the KEDA interceptor holds the request. Custom 503 page with auto-refresh shown if request times out.

## Cost Impact

| Scenario | Without KEDA | With KEDA | Savings |
|----------|-------------|-----------|---------|
| 3 tenants, 70% idle | 3 pods always -> ~$48/mo | ~0.9 pods avg -> ~$15/mo | ~69% |
| 100 tenants, 20% concurrency | 100 pods | ~20 pods peak | ~80% |

EBS volumes ($0.08/GB/mo for gp3) always charged: $0.80/mo per tenant at 10Gi.

## Always-On Mode

By default, tenant Pods scale to zero after 15 minutes of no HTTP traffic. This is ideal for interactive workspaces but breaks background tasks like OpenClaw cron jobs, which run inside the gateway process and don't generate external HTTP requests.

Set `alwaysOn: true` in the ApplicationSet element spec to keep the Pod running 24/7:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Tenant
metadata:
  name: my-tenant
spec:
  alwaysOn: true   # keeps minReplicas=1, Pod never scales to zero
  # ...
```

| Mode | minReplicas | Cron jobs | Cost |
|------|-------------|-----------|------|
| `alwaysOn: false` (default) | 0 | Stop when Pod scales down | Pay per use |
| `alwaysOn: true` | 1 | Run 24/7 | ~$15-30/mo per tenant |

The Operator passes `scaleToZero.enabled` and `scaleToZero.minReplicas` to the Helm chart via ArgoCD Application values, based on the ApplicationSet element `alwaysOn` field.

## Manual Override

> Note: For ArgoCD-managed tenants, direct `helm upgrade` changes will be reverted by ArgoCD's selfHeal. To change scale-to-zero settings, update the Operator's KEDA HSO logic or the ArgoCD Application values.

## Prerequisites

KEDA + HTTP Add-on must be installed:

```bash
./scripts/setup-keda.sh
```
