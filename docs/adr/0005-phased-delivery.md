# ADR-0005: Phased delivery — lifecycle → router/hibernation → gVisor

- **Status:** Proposed
- **Date:** 2026-06-18
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0001](0001-adopt-agent-sandbox-model.md), [ADR-0003](0003-per-tenant-sandboxtemplate.md), [ADR-0004](0004-defer-hibernation-and-router.md)

## Context

Adopting agent-sandbox touches three independent risk surfaces: the
**lifecycle model** (Deployment → Sandbox), the **scale-to-zero data path**
(KEDA → router + hibernation), and the **runtime/isolation tier** (runc →
gVisor, which needs new node infrastructure). Bundling them into one change
makes review and deploy-verification hard and couples unrelated risks.

Each PR must be validated by a **real deployment** (profile `hclo-mac`,
`us-east-1`) before it is promoted: verify on the `snese` repo first, then open
the PR to `aws-samples` and sync the `gitlab` remote.

## Decision

Deliver in three phases, each independently deploy-verifiable.

### PR #1 — Sandbox lifecycle adoption (runc)
- Install controller + CRDs (done) and a per-tenant `SandboxTemplate` carrying
  the full pod spec, SA, Secret, PVC, env (ADR-0003), `runtimeClassName` unset
  (runc), `envVarsInjectionPolicy: Allowed`.
- ApplicationSet emits a per-tenant `SandboxTemplate` + `SandboxClaim`.
- Repoint the per-tenant `HTTPRoute` backend to the Sandbox headless Service;
  remove the KEDA `HTTPScaledObject`; `operatingMode: Running` (ADR-0004).
- **Verify:** claim → Sandbox Ready → OpenClaw reachable via existing path →
  Bedrock call succeeds via Pod Identity. Risk is confined to the lifecycle
  model; runtime stays runc.

### PR #1.5 — Scale-to-zero redesign (gated)
- Resolve the wake mechanism and path→header strategy (ADR-0004 open items),
  each in its own ADR.
- Adopt sandbox-router, hibernation, heartbeat keepalive for the
  background-work hazard (an agent doing inbound-traffic-free work must not be
  hibernated mid-task).
- **Verify:** idle → hibernate → reconnect → state preserved.

### PR #2 — gVisor runtime tier
- `gvisor` `RuntimeClass`; a gVisor-capable **ARM64** Karpenter NodePool
  (AL2023 + `runsc` shim via user-data — the ai-on-eks reference NodePool is
  x86 and must be adapted to ARM64).
- Flip the per-tenant template's `runtimeClassName` to `gvisor` via a Helm value
  (ADR-0003 makes this a one-field change).
- **Sequencing constraint:** the gVisor NodePool must exist before any claim
  schedules a gVisor pod, or scheduling fails.

### Out of scope (future)
- FQDN egress enforcement (Cilium `toFQDNs` on Standard EKS, or native
  `ApplicationNetworkPolicy` on EKS Auto Mode). Auto Mode does not support
  gVisor, so the two are mutually exclusive — a CNI decision deferred until
  there is a concrete requirement.

## Consequences

**Positive**
- Each PR has a single, focused risk surface and a clear deploy-verification
  bar.
- gVisor on ARM64 is verified feasible, so the all-Graviton cluster needs no x86
  migration.

**Negative**
- The full value proposition (kernel isolation + scale-to-zero) is only complete
  after PR #2 and PR #1.5 respectively; interim states are explicitly partial
  (always-on after PR #1; runc-only until PR #2).

## References

- [docs/agent-sandbox.md](../agent-sandbox.md)
- gVisor ARM64 compatibility: https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/
