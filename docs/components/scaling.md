# Scale-to-Zero & Autoscaling

## Overview

Idle tenant pods scale to 0 replicas via KEDA HTTP Add-on. When an HTTP request arrives, the interceptor proxy holds it, triggers scale-up, and forwards once the pod is ready. PVC data survives scale-to-zero.

## How KEDA HTTP Add-on Works

```
                    ┌─────────────────────────────────────────────┐
                    │                  Kubernetes                  │
                    │                                             │
  Client ──► ALB ──┼──► KEDA HTTP Interceptor Proxy ──► Pod      │
             (host │       (holds request if pod=0)        (0→1)  │
             based │                                     │        │
             route)│                                     ▼        │
                    │                                   PVC       │
                    │                                  (gp3 10Gi) │
                    └─────────────────────────────────────────────┘
```

This is **not** KEDA core's HTTP scaler. The HTTP Add-on includes its own interceptor proxy that buffers requests while pods are starting.

**Request flow:**
1. Pod running → interceptor proxies directly to pod
2. Pod at 0 → interceptor holds request → triggers scale to 1
3. Pod starts (15-30s) → interceptor forwards buffered request
4. Pod idle 15min → KEDA scales back to 0

**ALB health checks:** The interceptor responds to health checks even when the pod is at 0 replicas, so ALB never marks the target as unhealthy.

## HTTPScaledObject

**Location:** `helm/charts/openclaw-platform/templates/httpscaledobject.yaml`

Created per tenant when `scaleToZero.enabled = true`:

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: {{ include "openclaw-helm.fullname" . }}
spec:
  hosts:
    - {{ .Values.ingress.host }}
  pathPrefixes:
    - /
  scaleTargetRef:
    name: {{ include "openclaw-helm.fullname" . }}
    kind: Deployment
    apiVersion: apps/v1
    service: {{ include "openclaw-helm.fullname" . }}
    port: {{ .Values.service.port }}
  replicas:
    min: 0
    max: 1
  scalingMetric:
    requestRate:
      granularity: 1s
      targetValue: 1
      window: 900s  # 15 min idle timeout
```

**Helm values:**

```yaml
scaleToZero:
  enabled: false    # set true to enable
  idleTimeout: 900  # seconds (15 min)
  minReplicas: 0
  maxReplicas: 1
```

**Constraints:**
- PVC is `ReadWriteOnce` — only one pod can mount it → `maxReplicas` must be 1
- HPA and HTTPScaledObject are mutually exclusive — do not enable both

## PVC Persistence

KEDA only changes the Deployment replica count. The PersistentVolumeClaim remains bound to the EBS volume. When the pod scales back up, it mounts the same PVC with all data intact.

```yaml
# pvc.yaml
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
```

## Cold Start

When a pod scales from 0 → 1:

| Phase | Duration | What happens |
|-------|----------|--------------|
| Pod scheduling | ~2s | Scheduler assigns node |
| Image pull | ~5-15s | First time only; cached after |
| `init-config` | ~2s | Copy default config to PVC |
| `init-skills` | ~5-10s | Install skills via clawhub (skips if already on PVC) |
| `init-tools` | ~3-5s | Install AWS SDK, patch Pod Identity, copy fetch-secret |
| Gateway startup | ~3-5s | OpenClaw gateway binds port |
| **Total (first)** | **~20-40s** | |
| **Total (cached)** | **~15-20s** | Image + skills already on node/PVC |

During cold start, the KEDA interceptor holds the request. The user sees the custom 503 page if the request times out before the pod is ready.

## Custom 503 Error Page

**Location:** `helm/charts/openclaw-platform/static/503.html`

Served via CloudFront custom error response + S3 OAC when the origin returns 503:

```
Client → CloudFront → ALB → KEDA interceptor (503 during cold start)
                ↓
         CloudFront custom error response
                ↓
         S3 bucket (OAC) → 503.html
```

The page shows an animated OpenClaw logo with "Waking up your assistant..." and auto-refreshes every 5 seconds:

```html
<meta http-equiv="refresh" content="5">
<h1>Waking up your assistant...</h1>
<p>Usually takes 15-30 seconds</p>
```

## Cost Impact

| Scenario | Without KEDA | With KEDA | Savings |
|----------|-------------|-----------|---------|
| 3 tenants, 70% idle | 3 pods always → ~$48/mo | ~0.9 pods avg → ~$15/mo | ~69% |
| 100 tenants, 20% concurrency | 100 pods | ~20 pods peak | ~80% |

EBS volumes ($0.08/GB/mo for gp3) are always charged regardless of pod state. At 10Gi per tenant: $0.80/mo per tenant.

## Enable / Disable

```bash
# Enable scale-to-zero for a tenant
helm upgrade openclaw-<name> helm/charts/openclaw-platform \
  -n openclaw-<name> --set scaleToZero.enabled=true --reuse-values

# Disable (pod stays at replicas=1)
helm upgrade openclaw-<name> helm/charts/openclaw-platform \
  -n openclaw-<name> --set scaleToZero.enabled=false --reuse-values
```

## Prerequisites

KEDA + HTTP Add-on must be installed on the cluster:

```bash
./scripts/setup-keda.sh
```
