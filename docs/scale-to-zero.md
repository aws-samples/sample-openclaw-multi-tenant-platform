# Scale to Zero: KEDA HTTP Add-on

## Goal

Automatically scale idle tenant pods to 0 replicas. When an HTTP request arrives, scale back to 1 within 15-30 seconds. This reduces compute cost for multi-tenant environments where most users are not active 24/7.

## How It Works

[KEDA HTTP Add-on](https://github.com/kedacore/http-add-on) provides an interceptor proxy that sits between the ALB and the tenant pod. When the pod is scaled to 0, the interceptor holds incoming requests, triggers a scale-up, and forwards the request once the pod is ready.

**This is different from KEDA core's HTTP scaler.** The HTTP Add-on includes its own interceptor proxy that can buffer requests while pods are starting.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │                  Kubernetes                  │
                    │                                             │
  Client ──► ALB ──┼──► KEDA HTTP Interceptor Proxy ──► Pod      │
             (host │       (holds request, triggers scale)  (0→1) │
             based │                                     │        │
             route)│                                     ▼        │
                    │                                   PVC       │
                    │                                  (gp3 10Gi) │
                    └─────────────────────────────────────────────┘

Flow:
1. Pod running   → Interceptor proxies directly to Pod
2. Pod scaled to 0 → Interceptor holds request → triggers scale to 1
3. Pod starts (~15-30s) → Interceptor forwards buffered request
4. Pod idle 15min → KEDA scales back to 0
```

## Data Persistence

**PVC (EBS volume) is NOT deleted when the pod scales to 0.** KEDA only changes the Deployment replica count. The PersistentVolumeClaim remains bound to the EBS volume. When the pod scales back up, it mounts the same PVC with all data intact.

## Installation

```bash
# Install KEDA + HTTP Add-on
./scripts/setup-keda.sh

# Enable scale-to-zero for a tenant
helm upgrade openclaw-<name> helm/charts/openclaw-platform \
  -n openclaw-<name> --set scaleToZero.enabled=true --reuse-values
```

## Helm Configuration

```yaml
scaleToZero:
  enabled: false    # Set to true to enable
  idleTimeout: 900  # 15 minutes (seconds)
  minReplicas: 0
  maxReplicas: 1
```

The `httpscaledobject.yaml` template creates a KEDA `HTTPScaledObject` CRD when enabled.

## Cold Start Time

When a pod scales from 0 to 1, the startup time includes:

| Phase | Duration |
|-------|----------|
| Pod scheduling | ~2s |
| Image pull (if not cached) | ~5-15s |
| init-config container | ~2s |
| init-skills container | ~5-10s |
| init-tools container | ~3-5s |
| OpenClaw gateway startup | ~3-5s |
| **Total** | **~15-40s** |

After the first cold start, the image is cached on the node, reducing subsequent starts to ~15-20s.

## Cost Impact

With 3 tenants idle 70% of the time:
- Without KEDA: 3 pods always running → ~$48/mo EC2
- With KEDA: ~0.9 pods average → ~$15/mo EC2
- **Savings: ~$33/mo (69%)**

At 100 tenants with 20% concurrency:
- Without KEDA: 100 pods → significant EC2 cost
- With KEDA: ~20 pods peak → 80% reduction

## Notes

- ALB health checks: KEDA interceptor responds to health checks even when the pod is at 0 replicas
- PVC is `ReadWriteOnce` — only one pod can mount it at a time (maxReplicas should stay at 1)
- HPA and HTTPScaledObject are mutually exclusive — do not enable both
- Custom 503 error page (`static/503.html`) can be served during cold start via ALB configuration
