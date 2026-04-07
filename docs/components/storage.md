# Data Persistence & Backup

## Overview

Each tenant gets an EFS-backed PVC that persists across pod restarts, scale-to-zero, and AZ failures. Amazon EFS CSI driver dynamically provisions per-tenant Access Points for isolation.

## Storage Architecture

```
EFS FileSystem (encrypted, elastic throughput)
  ├─ /tenants/openclaw-alice/    ← Access Point (auto-created by CSI driver)
  ├─ /tenants/openclaw-bob/      ← Access Point
  └─ /tenants/openclaw-demo/     ← Access Point

Each AP enforces:
  - RootDirectory chroot (tenant cannot traverse up)
  - POSIX UID/GID 1000:1000 (matches OpenClaw container user)
```

## PVC Configuration

**Helm values** (`values.yaml`):

```yaml
persistence:
  enabled: true
  storageClass: "efs-sc"    # EFS dynamic provisioning
  accessMode: ReadWriteMany  # EFS supports multi-AZ
  size: 10Gi                 # EFS auto-scales; this is a K8s formality
```

**StorageClass** (`efs-sc`, created by AWS CDK):

```yaml
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-xxx
  directoryPerms: "0755"
  basePath: "/tenants"
  subPathPattern: "${.PVC.namespace}"
```

**Mount point:** `/home/node/.openclaw`

**Lifecycle:**
- PVC created automatically when ArgoCD syncs tenant Helm chart
- CSI driver creates Amazon EFS Access Point on PVC creation
- PVC survives pod restart, scale-to-zero, and node failure
- `ReadWriteMany` — pod can start on any AZ node

## Cost

Amazon EFS charges per actual usage, not allocated capacity:

| Tier | Price | When |
|------|-------|------|
| Standard | $0.30/GB/mo | Frequently accessed |
| Infrequent Access | $0.025/GB/mo | After 30 days without access |

Typical tenant: ~500MB actual usage → ~$0.15/mo (vs $0.80/mo with EBS 10Gi).

## Isolation

| Layer | Mechanism |
|-------|-----------|
| Access Point chroot | Amazon EFS server-side enforced, cannot traverse up |
| K8s PV binding | Pod can only mount its assigned PV |
| Pod Security Standards | `restricted` profile, no CAP_SYS_ADMIN |
| K8s RBAC | No cross-namespace access |

## Backup

Amazon EFS supports AWS Backup natively. For on-demand backup/restore:

```bash
# Backup tenant data to S3
./scripts/backup-tenant.sh <tenant-name> <s3-bucket>

# Restore from S3
./scripts/restore-tenant.sh <tenant-name> s3://<bucket>/backups/<tenant>/<file>.tar.gz
```

## Production: Per-Tenant Quota

Amazon EFS has no per-access-point quota. For hard quota requirements:

| Solution | Hard Quota | Min Cost |
|----------|-----------|----------|
| Amazon EFS + CronJob monitoring | Soft only | ~$0.30/GB |
| FSx for OpenZFS | ✅ Native UserQuota | ~$150/mo |
| FSx for NetApp ONTAP | ✅ Native Volume quota | ~$300/mo |

The Helm chart's StorageClass abstraction works with all three — migration to FSx requires no Helm chart changes.

## Limits

- Amazon EFS Access Points: 1000 per filesystem
- Amazon EFS throughput: elastic mode auto-scales (up to 10 GiB/s read, 3 GiB/s write)
- No per-AP storage quota (see Production section above)
