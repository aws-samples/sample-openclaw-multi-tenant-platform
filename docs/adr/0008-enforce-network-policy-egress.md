# ADR-0008: Enforce per-tenant egress control via Amazon VPC CNI NetworkPolicy

- **Status:** Accepted
- **Date:** 2026-07-14
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0007](0007-gvisor-runtime-tier.md)

## Context

For multi-tenant agent workloads, the highest-leverage isolation control is not
the container runtime — it is **egress control**. Credential exfiltration and
lateral movement use perfectly normal syscalls that any runtime (runc, gVisor,
microVM) permits; only the network layer can stop them (see the mechanism table
in ADR-0007).

The Helm chart has always shipped a per-tenant `NetworkPolicy`
(`networkPolicy.enabled: true` by default) that is effectively default-deny:

- **Egress allowed:** DNS, Amazon EKS Pod Identity Agent (`169.254.170.23`), IMDS,
  TCP 443 to public IPs (except `10.0.0.0/8`), same-namespace pods.
- **Everything else denied:** cross-tenant traffic, VPC-internal addresses,
  non-443 protocols.

**However, on Amazon EKS these objects were stored but not enforced.** The Amazon VPC
CNI's NetworkPolicy support is disabled by default and must be enabled
explicitly on the add-on; nothing in this stack did so. The policy was
decorative.

## Decision

1. Enable NetworkPolicy enforcement on the `vpc-cni` managed add-on via
   `configurationValues: {"enableNetworkPolicy": "true"}` (CDK).
2. Keep the existing per-tenant policy as-is (HTTPS-only egress posture).
3. Treat FQDN-level egress filtering as a documented **non-goal** with an
   upgrade path (below), not a platform feature.

## What this changes for agent behavior

| Tenant/agent behavior | After enforcement |
|-----------------------|-------------------|
| HTTPS APIs and sites (Amazon Bedrock, AWS Secrets Manager, ghcr.io, npm, web tools over 443) | Unchanged |
| Pod Identity, IMDS, DNS, same-namespace | Unchanged (explicit allows) |
| Amazon EFS mounts | Unchanged (NFS mount runs in the node network namespace, not the pod's) |
| Plain-HTTP (`http://`, port 80) external sites | **Blocked** |
| Non-443 protocols (SSH/git :22, custom :8080, SMTP) | **Blocked** |
| VPC-internal / cross-tenant addresses (`10.0.0.0/8`) | **Blocked** |

## Residual risk (stated honestly)

Egress to **any** public host on TCP 443 remains allowed. An agent that is
prompt-injected into exfiltrating data over HTTPS is *not* stopped by this
policy. Kubernetes `NetworkPolicy` is L3/L4 and cannot express hostnames.

## Upgrade path (non-goals for this sample)

- **AWS Network Firewall** — VPC-level FQDN/SNI allowlisting; cluster-wide
  granularity, no chart changes.
- **CNI with DNS-aware policy (e.g. Cilium)** — per-tenant FQDN allowlists;
  requires replacing the CNI, too heavy for this sample.
- **Egress proxy (allowlist + audit)** — strongest auditability; requires the
  agent tool-chain to honor proxy configuration.

## Options considered

- **Enforce existing policy (chosen):** one add-on setting; per-tenant
  granularity; zero new components.
- **AWS Network Firewall now:** rejected for the sample — cost + VPC redesign,
  and cluster-level (not per-tenant) granularity.
- **Do nothing:** rejected — shipping an unenforced NetworkPolicy misleads
  adopters about the actual security posture.

## Consequences

**Positive**
- The documented tenant isolation model ("Namespace isolation + NetworkPolicy +
  ABAC") becomes true.
- Blocks metadata-service and cross-tenant lateral movement paths.

**Negative / caveats**
- Agent tools that need port-80 or non-443 endpoints require an explicit
  per-tenant policy exception.
- Adopters whose VPC CIDR is outside `10.0.0.0/8` should adjust the `except`
  block to their VPC CIDR (documented in `values.yaml`).
- Enforcement behavior at pod startup is *standard mode* (default-allow until
  policies attach); see the EKS docs if strict mode is required.

## References

- https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html
- https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html
