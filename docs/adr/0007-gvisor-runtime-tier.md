# ADR-0007: gVisor runtime tier — selectable kernel isolation on all-Graviton EKS

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0001](0001-adopt-agent-sandbox-model.md), [ADR-0003](0003-per-tenant-sandboxtemplate.md), [ADR-0005](0005-phased-delivery.md)

## Context

The runc tier shipped in PR #1 provides namespace + NetworkPolicy + Pod Identity
ABAC isolation, but not kernel-level isolation: a container escape reaches the
shared host kernel. For multi-tenant agent workloads that execute
partially-trusted, model-driven tool calls (subprocess exec, arbitrary I/O), a
stronger boundary is desirable.

Two kernel-isolation options exist on EKS, both selectable per-pod via
`runtimeClassName` (the mechanism agent-sandbox already supports):

- **gVisor (runsc):** a user-space kernel (Sentry) that intercepts syscalls.
  Runs on **standard nodes** (no bare metal / nested virt), so it fits our
  all-Graviton (ARM64) cluster directly. Lower overhead and higher density than a
  VM; weaker isolation than a VM and a known partial syscall/`iptables` surface.
- **Kata Containers (QEMU/KVM microVM):** strongest (hypervisor) boundary, but
  requires bare metal or nested virtualization and carries per-pod VM overhead
  (~282 MiB RSS, guest kernel, slower cold start, lower density).

This sample targets density and cost on standard Graviton, with isolation as a
**selectable** property rather than a fixed platform-wide VM cost. gVisor matches
that posture; Kata is the right tool when a compliance/threat model mandates
hardware-level isolation, and remains available via the same `runtimeClassName`
mechanism for adopters who need it.

## Decision

- Add a **selectable gVisor tier** alongside the runc tier, off by default,
  enabled per-deployment via the `sandbox.runtimeClassName: gvisor` Helm value.
- **Node infrastructure (CDK):** a dedicated, **tainted** gVisor Karpenter
  `NodePool` (AL2023, **ARM64-preferred**) whose `EC2NodeClass` `userData` installs the
  `runsc` + `containerd-shim-runsc-v1` artifacts and registers the runtime; plus a
  `gvisor` `RuntimeClass` (`handler: runsc`) pinned to the pool via
  `scheduling.nodeSelector`, with `overhead.podFixed` set so the scheduler
  accounts for the per-pod Sentry cost.
- **Architecture support:** Graviton (`arm64`) is the preferred/default
  architecture (NodePool `weight: 100`); an `amd64` fallback pool (`weight: 10`)
  shares the same `EC2NodeClass` — the userData resolves the gVisor release
  binary via `$(uname -m)`, and the tenant image (`ghcr.io/openclaw/openclaw`) is
  published multi-arch, so both architectures work without divergence.
- **Tenant scheduling (Helm):** the per-tenant `SandboxTemplate`
  (`spec.podTemplate.spec`) sets `runtimeClassName: gvisor` and adds the gVisor
  pool `nodeSelector` + `NoSchedule` toleration when the gVisor value is set.
- **Keep the uniform Pod Identity tenant model** for both tiers (no IRSA
  divergence) — verified reachable under gVisor (see below).

## Phase 0 verification (gates, completed 2026-06-24)

- **R1 — runsc install on AL2023 ARM64:** verified against gVisor docs + the
  `awslabs/ai-on-eks` official gVisor sample (we adapt their x86 pattern to arm64).
  **Correction captured:** on AL2023/EKS containerd **v2**, the runtime config path
  is `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]` — the
  legacy `grpc.v1.cri` path shown in the gVisor quick-start is silently ignored.
- **R2 — Pod Identity under gVisor (KILL-CRITERION): PASS.** A `runtimeClassName=gvisor`
  pod with a tenant ServiceAccount reached the Pod Identity Agent at
  `http://169.254.170.23/...` and returned the tenant role, identical to runc.
  gVisor `network=sandbox` (its own netstack) **does** see the host link-local
  DNAT, so the IRSA divergence considered in design is **not** needed.
- **R5 — scheduling fields:** `SandboxTemplate.spec.podTemplate.spec` passes
  through `runtimeClassName` + `tolerations`; matches the official gvisor template.

## Verification evidence (live, this codebase)

Fresh `cdk deploy` of the full stack on a net-new stack (`hclo-mac`/`us-east-1`):

- Stack reached **CREATE_COMPLETE** (no manual resource creation).
- A `runtimeClassName=gvisor` pod, scheduled by Karpenter onto a node labelled
  `openclaw/runtime=gvisor` (**arm64**), reported `/proc/version =
  Linux 4.19.0-gvisor`, `uname -m = aarch64`, and `dmesg` "Starting gVisor..." —
  confirming the gVisor kernel, not the host kernel.
- The runc tier (PR #1) is unchanged: the gVisor pool is tainted and selected only
  by pods that request the `gvisor` RuntimeClass.
- Earlier full E2E (2026-06-24) additionally validated EFS RWX mount and a real
  OpenClaw image (Node.js 24 + crypto + Bedrock) under gVisor on arm64.

> Build/synth/lint success is not sufficient; the above is end-to-end runtime
> evidence on a CDK-deployed cluster, per the project verification bar.

## Options considered

- **gVisor selectable tier (chosen):** fits all-Graviton standard nodes, low
  overhead, isolation as an opt-in property.
- **Kata as the default isolation tier:** rejected as default — forces bare
  metal / nested virt and per-pod VM cost on every tenant. Remains available via
  `runtimeClassName` for adopters with hardware-isolation requirements.
- **runc only:** rejected — no kernel-level isolation for partially-trusted agent
  workloads.

## Consequences

**Positive**
- Kernel-attack-surface reduction available per-tenant without leaving standard
  Graviton or paying VM overhead platform-wide.
- No tenant-provisioning divergence (Pod Identity uniform across tiers).

**Negative / caveats**
- gVisor implements a **subset** of the Linux syscall ABI and **partially**
  supports `iptables`; syscall coverage is workload-dependent — adopters should
  E2E-test their own tool surface. Service-mesh **sidecars** (Envoy, iptables-based
  redirect) are awkward inside gVisor; ambient/sidecarless mesh or Kata are the
  alternatives.
- `runsc` adds per-syscall interception overhead vs runc (acceptable for agent
  workloads; measure if latency-sensitive).
- Pin agent-sandbox version: gVisor template scheduling fields validated against
  v0.4.5 — re-validate on upgrade.

## What each layer actually buys (mechanism honesty)

| Layer | Mechanism | Stops | Does NOT stop |
|-------|-----------|-------|---------------|
| Namespace + NetworkPolicy + ABAC (runc tier) | Logical isolation, L3/L4 egress rules, IAM session tags | Cross-tenant API/network access, lateral movement | Kernel exploits; exfiltration over allowed egress |
| gVisor tier | **Syscall interception** by a user-space kernel (Sentry) | Most host-kernel attack surface from container escape | Data exfiltration over permitted HTTPS; syscall-ABI-compatible abuse; it is *not* hardware virtualization |
| microVM-class runtime (e.g. Kata; future hardware-virtualized runtimes) | **Hardware virtualization** (separate guest kernel per pod) | Host kernel compromise from guest | Exfiltration over permitted egress; higher per-pod cost |

No runtime tier substitutes for egress control: credential exfiltration uses
perfectly normal syscalls and permitted HTTPS. See ADR-0008.

## Runtime tier extension contract

Any future runtime tier (e.g. a microVM-class runtime) plugs in through exactly
four seams — nothing else in the platform should need to change:

1. **`RuntimeClass`** — `handler` + `scheduling` (nodeSelector/tolerations) +
   `overhead.podFixed`.
2. **Karpenter `NodePool` + `EC2NodeClass`** — node label `openclaw/runtime=<tier>`,
   matching taint, userData (or AMI) that provides the runtime handler.
3. **Helm value `sandbox.runtimeClassName`** — the per-tenant `SandboxTemplate`
   passes it through; tenants flip tiers with a single value.
4. **Conformance pass** — `scripts/conformance-runtime-tier.sh <runtimeClassName>`
   must pass end-to-end (kernel identity, Pod Identity, EFS RWX, Bedrock invoke)
   on a CDK-deployed cluster before the tier is documented as supported.

**Tier policy: at most two runtime tiers at any time (runc + one hardened
tier). A new hardened tier replaces the previous one rather than accumulating**
— three concurrent tiers triple the verification and maintenance surface of a
sample without adding architectural insight.

## References

- gVisor compatibility: https://gvisor.dev/docs/user_guide/compatibility/
- gVisor install: https://gvisor.dev/docs/user_guide/install/
- ai-on-eks agent-sandbox gVisor sample: https://awslabs.github.io/ai-on-eks/
