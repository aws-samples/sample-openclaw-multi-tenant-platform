# Data Persistence & Backup

## Overview

Each tenant gets a 10Gi gp3 EBS PVC that persists across pod restarts and scale-to-zero. Two backup strategies: daily EBS snapshots (CronJob) and on-demand S3 backup/restore (scripts).

## PVC Configuration

**Helm chart template**: `helm/charts/openclaw-platform/templates/pvc.yaml`

The Operator creates the PVC via `ensure_pvc`. For ArgoCD-managed tenants, the Helm chart also includes a PVC template.

```yaml
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
```

**Mount point:** `/home/node/.openclaw`

**Lifecycle:**
- PVC is **not deleted** on `helm uninstall` (Kubernetes default)
- Survives pod restart and scale-to-zero
- `ReadWriteOnce` -- enforces single-replica constraint

**Cost:** gp3 at $0.08/GB/mo -> $0.80/mo per tenant for 10Gi.

## Daily EBS Snapshot CronJob

**Location:** `scripts/pvc-backup-cronjob.yaml`

Runs daily at 03:00 UTC. Discovers all OpenClaw PVCs, creates EBS snapshots, cleans up snapshots older than 7 days.

Works regardless of pod state -- snapshots are at the EBS volume level.

## S3 Backup / Restore Scripts

For on-demand backup and cross-region restore. KEDA-aware -- auto-scales pod up if at 0.

```bash
# Backup
./scripts/backup-tenant.sh <tenant-name> <s3-bucket>
# -> s3://<bucket>/backups/<tenant>/<tenant>-<timestamp>.tar.gz

# Restore
./scripts/restore-tenant.sh <tenant-name> s3://<bucket>/backups/<tenant>/<file>.tar.gz
```

**Naming convention:** namespace is `openclaw-{name}`, deployment is `{name}`.

## Backup Strategy Summary

| Method | Frequency | Scope | Requires Pod | Retention |
|--------|-----------|-------|-------------|-----------|
| EBS snapshot (CronJob) | Daily 03:00 UTC | All tenants | No | 7 days |
| S3 backup (script) | On-demand | Single tenant | Yes (auto-scales) | Manual |
