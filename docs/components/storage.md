# Data Persistence & Backup

## Overview

Each tenant gets a 10Gi gp3 EBS PVC that persists across pod restarts and scale-to-zero. Two backup strategies: daily EBS snapshots (CronJob) and on-demand S3 backup/restore (scripts).

## PVC Configuration

**Location:** `helm/charts/openclaw-platform/templates/pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi  # values.persistence.size
```

**Mount point:** `/home/node/.openclaw` — contains workspace, sessions, config, installed skills, and tools.

**Lifecycle:**
- PVC is created by Helm and **not deleted** on `helm uninstall` (Kubernetes default for PVCs)
- Survives pod restart — Deployment recreates pod, mounts same PVC
- Survives scale-to-zero — KEDA only changes replica count, PVC stays bound
- `ReadWriteOnce` — only one pod can mount at a time (enforces single-replica constraint)

**Cost:** gp3 at $0.08/GB/mo → $0.80/mo per tenant for 10Gi.

## Daily EBS Snapshot CronJob

**Location:** `scripts/pvc-backup-cronjob.yaml`

Runs daily at 03:00 UTC. Discovers all OpenClaw PVCs, creates EBS snapshots, and cleans up snapshots older than 7 days.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openclaw-pvc-backup
  namespace: kube-system
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
```

**How it works:**

1. List all PVCs with label `app.kubernetes.io/name=openclaw-helm` across all namespaces
2. For each PVC, resolve the EBS volume ID from the PersistentVolume's `.spec.csi.volumeHandle`
3. Create an EBS snapshot with tags:
   - `Name: openclaw-backup-{namespace}`
   - `openclaw/namespace: {namespace}`
   - `openclaw/backup: true`
4. Delete snapshots older than 7 days (filtered by `openclaw/backup=true` tag)

**RBAC:** The CronJob uses a `pvc-backup` ServiceAccount with a ClusterRole that can `get` and `list` PVs and PVCs.

**IAM:** IRSA role with `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:DescribeSnapshots`, `ec2:CreateTags`.

**Key detail:** This works regardless of pod state — snapshots are taken at the EBS volume level, not from inside the pod. No need to scale up.

## S3 Backup / Restore Scripts

For on-demand backup and cross-region restore. These scripts are KEDA-aware — they handle scale-up if the pod is at 0.

### backup-tenant.sh

**Location:** `scripts/backup-tenant.sh`

```bash
./scripts/backup-tenant.sh <tenant-name> <s3-bucket>
# → s3://<bucket>/backups/<tenant>/<tenant>-<timestamp>.tar.gz
```

**Flow:**

1. Check if pod is running; if scaled to zero, `kubectl scale --replicas=1` and wait
2. `kubectl exec` — tar the workspace inside the pod: `tar czf /tmp/backup.tar.gz -C /home/node/.openclaw .`
3. `kubectl cp` — copy tar out of pod
4. `aws s3 cp` — upload to S3
5. If script scaled the pod up, scale back to 0

### restore-tenant.sh

**Location:** `scripts/restore-tenant.sh`

```bash
./scripts/restore-tenant.sh <tenant-name> s3://<bucket>/backups/<tenant>/<file>.tar.gz
```

**Flow:**

1. Check if pod is running; if scaled to zero, scale up and wait
2. `aws s3 cp` — download from S3
3. `kubectl cp` — copy tar into pod
4. `kubectl exec` — extract: `tar xzf /tmp/restore.tar.gz -C /home/node/.openclaw`
5. Cleanup temp files (does **not** auto-scale back down after restore)

### KEDA-Aware Scale Handling

Both scripts share the same pattern:

```bash
SCALED_UP=false
if ! kubectl -n "$NS" get pods -l "$POD_LABEL" \
     --field-selector=status.phase=Running -o name | grep -q .; then
  echo "==> Pod scaled to zero, scaling up..."
  kubectl -n "$NS" scale deployment "openclaw-${TENANT}" --replicas=1
  kubectl -n "$NS" rollout status deployment "openclaw-${TENANT}" --timeout=120s
  SCALED_UP=true
fi
```

**Naming convention:** namespace is `tenant-{name}`, deployment is `openclaw-{name}`, pod label is `app.kubernetes.io/instance=openclaw-{name}`.

## Backup Strategy Summary

| Method | Frequency | Scope | Requires Pod | Retention |
|--------|-----------|-------|-------------|-----------|
| EBS snapshot (CronJob) | Daily 03:00 UTC | All tenants | No | 7 days |
| S3 backup (script) | On-demand | Single tenant | Yes (auto-scales) | Manual |

**When to use which:**
- **EBS snapshots** — disaster recovery, volume-level restore, automated
- **S3 backup** — cross-region migration, selective restore, sharing between environments
