# Multi-Region Design

> Status: **Design Document** — not yet implemented.

## Overview

Extend the OpenClaw platform from a single-region deployment (us-west-2) to an active-passive dual-region architecture. The secondary region serves as a warm standby for disaster recovery, with automated failover via Route53 health checks.

## Architecture

```
                        Route53 Failover
                     ┌──────────────────────┐
                     │  Primary: us-west-2   │ ◄── Active
                     │  Secondary: us-east-1 │ ◄── Passive (warm standby)
                     └──────┬───────┬───────┘
                            │       │
              ┌─────────────┘       └─────────────┐
              ▼                                   ▼
   ┌─────────────────────┐            ┌─────────────────────┐
   │     us-west-2       │            │     us-east-1       │
   │                     │            │                     │
   │  CloudFront ──► EKS │            │  CloudFront ──► EKS │
   │  Cognito            │            │  Cognito            │
   │  S3 (auth UI)       │  ──sync──► │  S3 (auth UI)       │
   │  EBS (tenant PVCs)  │  ──repl──► │  EBS (tenant PVCs)  │
   │  Secrets Manager    │  ──repl──► │  Secrets Manager     │
   └─────────────────────┘            └─────────────────────┘
```

## Components

### 1. Route53 Failover Routing

- **Primary record**: `your-domain.com` → us-west-2 CloudFront distribution (failover routing, primary)
- **Secondary record**: `your-domain.com` → us-east-1 CloudFront distribution (failover routing, secondary)
- **Health check**: HTTP GET against the primary ALB health endpoint (`/healthz`), 30-second interval, 3 failure threshold
- **Failover time**: ~90 seconds (3 × 30s health check failures) + DNS TTL (60s recommended)

### 2. EKS Cluster (Secondary Region)

- Mirror the primary cluster configuration via CDK / Terraform
- Same node groups, KEDA, ArgoCD setup
- Tenant pods scaled to 0 in passive mode (no compute cost when idle)
- On failover: KEDA scales pods as requests arrive

### 3. Data Replication

#### Option A: S3 Cross-Region Replication (Recommended for auth UI + static assets)

- S3 CRR from us-west-2 to us-east-1, same-account replication
- Replication time: typically < 15 minutes (S3 RTC guarantees 99.99% within 15 min)
- Auth UI bucket and error pages bucket both replicated

#### Option B: EBS Snapshots for Tenant PVCs

- Automated EBS snapshots via AWS Backup (every 1 hour)
- Cross-region copy to us-east-1
- On failover: restore snapshots to EBS volumes in us-east-1
- **RPO**: up to 1 hour of data loss
- **RTO**: ~10-15 minutes (snapshot restore + pod startup)

#### Option C: S3 as Primary Storage (Alternative)

- Replace EBS PVCs with S3-backed storage (via Mountpoint for S3 CSI driver)
- S3 CRR handles replication automatically
- Trade-off: higher latency for small file I/O, but simpler replication story

### 4. Cognito — Regional Service

Cognito User Pools are **regional** with no built-in cross-region replication. Options:

| Strategy | Pros | Cons |
|----------|------|------|
| **Dual user pools + Lambda sync** | Full independence per region | Complex sync logic, eventual consistency |
| **Single pool in us-west-2 + cross-region API calls** | Simple, single source of truth | Secondary region depends on primary for auth |
| **Cognito + external IdP (e.g., Auth0)** | Global by design | Additional cost, migration effort |

**Recommendation**: Start with a single Cognito pool in us-west-2. The secondary region calls Cognito cross-region for authentication. This means auth is unavailable during a us-west-2 outage, but already-authenticated sessions (JWT tokens) remain valid until expiry. For full independence, migrate to dual pools with Lambda-based sync later.

### 5. Secrets Manager

- Enable [multi-region secret replication](https://docs.aws.amazon.com/secretsmanager/latest/userguide/create-manage-multi-region-secrets.html)
- Primary secret in us-west-2, replica in us-east-1
- Replication is near-real-time
- Secondary region pods reference the replica secret ARN

### 6. Global Accelerator (Optional)

An alternative to Route53 failover:

- Anycast IP addresses — no DNS propagation delay
- Health-check-based failover at the network layer
- Faster failover (~30 seconds vs ~90-150 seconds for DNS)
- Additional cost: $0.025/hr fixed + $0.015/GB data transfer

**When to use**: If sub-minute failover is a hard requirement. Otherwise, Route53 failover is simpler and cheaper.

## Failover Procedure

```
1. Route53 health check detects primary failure (3 consecutive failures)
2. DNS failover to secondary CloudFront distribution (~60-90s)
3. Requests hit us-east-1 EKS cluster
4. KEDA scales tenant pods from 0 → 1 as requests arrive (~15-30s)
5. Pods mount EBS volumes restored from latest snapshot
6. Total RTO: ~3-5 minutes (DNS + pod startup + volume attach)
```

### Failback

1. Restore primary region
2. Reverse-sync any data written to secondary during outage
3. Verify primary health checks pass
4. Route53 automatically routes back to primary (or manual DNS switch)

## Cost Estimate (Dual-Region)

| Component | Monthly Cost (Estimate) |
|-----------|------------------------|
| EKS cluster (us-east-1) | ~$73 (control plane only, nodes scale to 0) |
| EC2 nodes (warm standby, 2× t3.medium) | ~$60 (only during failover) |
| EBS snapshots cross-region copy | ~$5-15 (depends on data volume) |
| S3 CRR | ~$2-5 (small buckets) |
| Route53 health checks | ~$1.50 (2 health checks) |
| Secrets Manager replicas | ~$0.40/secret/month |
| Global Accelerator (if used) | ~$18 fixed + data transfer |
| **Total passive standby** | **~$80-95/month** |
| **Total with Global Accelerator** | **~$100-115/month** |

*Costs assume pods are scaled to 0 in the secondary region during normal operation. Compute costs increase during active failover.*

## Open Questions

1. Acceptable RPO/RTO targets — is 1-hour RPO (EBS snapshots) sufficient?
2. Should we invest in S3-backed storage (Option C) to simplify replication?
3. Cognito strategy — single pool acceptable for MVP, or dual pools from day one?
4. Global Accelerator — is sub-minute failover worth the extra ~$20/month?
