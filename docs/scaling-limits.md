# Scaling Limits

Honest ceilings for the 1-tenant = 1-namespace + 1-singleton-Sandbox design,
with what raises each one. Quota values verified against the AWS Service Quotas
API and official documentation on 2026-07-15; re-verify before capacity
planning — quotas change.

## TL;DR

**The first binding ceiling is ~85–100 tenants on the shared Gateway/ALB — not
the 5,000 Pod Identity limit.** Each tenant consumes ~1 ALB listener rule and
~1 target group; "Rules per ALB" (100) is adjustable by quota request, but
**"Target Groups per ALB" (100) is NOT adjustable**. A rules increase alone
does not raise this ceiling.

The sample ships a tenant-capacity guard: the post-confirmation flow refuses
new tenants past `gatewayTenantBudget` (CDK context, default 85) instead of
failing silently at tenant #101.

## Ceiling table

| Ceiling | Default | Adjustable? | First fix | Next constraint after fix |
|---|---|---|---|---|
| Target groups per ALB | 100 | **No** | Shard: additional Gateway/ALB per tenant cohort | Argo CD reconciliation envelope |
| Rules per ALB | 100 | Yes (quota request) | Raise alongside sharding | Target-group hard limit |
| Pod IPs per node | ENI-dependent | — | `ENABLE_PREFIX_DELEGATION` (enabled by this stack, ~16× density) | Subnet CIDR sizing |
| ApplicationSet in-object tenant list | ~1.5 MiB etcd object cap (low thousands) | — | Migrate to a Git directory generator (issue #16) | Argo CD controller load |
| EKS Pod Identity associations per cluster | 5,000 ([docs](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)) | No | Cell architecture (limit is per-cluster) | Per-cell tested envelope |
| Amazon EFS access points per file system | 10,000 | **No** | Shard file systems via per-cohort StorageClass | Per-FS throughput (binds earlier) |
| Always-on singleton cost | economic, every tier | — | Idle suspend (issue #14) | — |

## The honest story

This architecture is right up to roughly 85–90 tenants on one shared
Gateway/ALB. A rules-quota increase plus Gateway sharding buys a few hundred
tenants per shard. Beyond the low thousands, the correct evolution is
**cells**: replicate the entire unit (EKS cluster + Gateway/ALB + Argo CD +
EFS shards) at a load-tested envelope and assign tenants to cells at DNS.
Cells bound upgrade blast radius — which matters more to enterprise adopters
than a central dynamic router that would trade simple, auditable per-tenant
routing for a shared security-critical hop. Every fix moves the ceiling; none
removes it.

## What we deliberately did NOT build

- **In-cluster wildcard router** (O(1) ALB usage): converts static routing
  into a central discovery/authorization proxy — disproportionate for a
  reference sample. Documented here as an adopter-owned evolution.
- **Host-based tenant routing**: each tenant host still selects a distinct
  backend (same target-group consumption) while adding DNS/TLS/Cognito
  callback complexity. Not a ceiling raiser.
- **IRSA wildcard trust** to escape the Pod Identity association limit: loses
  automatic session tags, weakening the deliberate ABAC tenant boundary.
