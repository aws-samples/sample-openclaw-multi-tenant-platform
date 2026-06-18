# ADR-0001: Adopt the agent-sandbox model for tenant workspace isolation

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** HC Lo (hclo)
- **Tracking issue:** [#365](https://github.com/snese/sample-openclaw-multi-tenant-platform/issues/365)

## Context

Today each tenant workspace is a plain Kubernetes `Deployment`, isolated only
at the namespace and `NetworkPolicy` level. Model-generated and user-driven
code inside an OpenClaw workspace therefore runs against the full host-kernel
syscall surface. For a multi-tenant platform that executes semi-trusted,
LLM-driven workloads, this is the weakest part of the current design.

We also lack a first-class primitive for the thing each tenant actually is: a
**long-running, stateful, singleton workspace with a stable identity and
persistent storage**. Modelling that as a `Deployment` (stateless, replicated)
is a poor fit and forces us to hand-stitch Service, PVC, and scaling behaviour.

We want:

1. A kernel-level isolation tier we can turn on per workload.
2. A declarative, lifecycle-managed singleton primitive that matches the
   per-tenant persistent workspace model.
3. To stay AWS-native and avoid adding a heavy, non-AWS supply-chain dependency.

## Decision

Adopt the [kubernetes-sigs/agent-sandbox](https://agent-sandbox.sigs.k8s.io/)
model — the `Sandbox` CRD plus the `SandboxTemplate` / `SandboxClaim` /
`SandboxWarmPool` extensions — as packaged by
[awslabs/ai-on-eks](https://awslabs.github.io/ai-on-eks/docs/infra/agents/agent-sandbox).

The runtime is intentionally pluggable: this ADR commits only to the **model**.
The kernel-isolation tier (gVisor) is delivered later as a `SandboxTemplate`
`runtimeClassName` field, not as a separate layer (see ADR-0005).

## Options considered

### A. Status quo — namespace + NetworkPolicy only
Rejected. Provides no kernel isolation; model-generated code keeps the full
host syscall surface. Does not address the stateful-singleton modelling gap.

### B. NVIDIA OpenShell / NemoClaw
Rejected. It is alpha and host-centric (a single-machine, always-on agent
hardening CLI), and would have to be adapted into a sidecar/DaemonSet to fit a
multi-tenant cluster. Its headline value — inference-layer credential injection
so the agent never sees the API key — is **already provided** in this sample by
Amazon Bedrock + EKS Pod Identity (zero API keys), so the marginal benefit here
is effectively zero. Adopting it would also dilute the sample's "all
AWS-native" positioning and add NVIDIA supply-chain and support risk.

### C. kubernetes-sigs agent-sandbox (chosen)
Kubernetes-native CRDs purpose-built for isolated, stateful, singleton
workloads in multi-tenant clusters. Integrates cleanly with the existing stack
(Karpenter, ArgoCD ApplicationSet, Pod Identity/IRSA, NetworkPolicy, ResourceQuota).
gVisor and Kata are selectable per template rather than bespoke runtime layers.
Maintained by a Kubernetes SIG and packaged for EKS by awslabs/ai-on-eks.

## Consequences

**Positive**
- A declarative "singleton pod with stable identity + persistent storage"
  primitive that matches the per-tenant workspace model directly.
- Kernel isolation (gVisor) becomes a one-field change on a template (ADR-0005).
- Stays AWS-native + OSS SIG; no NVIDIA wrapper in the supply chain.

**Negative / costs**
- New control-plane dependency: the agent-sandbox controller + CRDs must be
  installed and operated (install script already added in PR #365).
- The API is still evolving; we must pin a version and track drift
  (see ADR-0002).
- The routing and scale-to-zero model must change, because a `Sandbox` is a
  singleton with no `/scale` subresource and the wake/hibernation path differs
  from the current KEDA HTTP add-on (see ADR-0004).
- Per-tenant identity (ServiceAccount), secrets, and storage must be expressed
  within the template/claim model rather than a hand-written Deployment
  (see ADR-0003).

## References

- [Agent Sandbox documentation](https://agent-sandbox.sigs.k8s.io/docs/)
- [awslabs/ai-on-eks — Agent Sandbox on EKS](https://awslabs.github.io/ai-on-eks/docs/infra/agents/agent-sandbox)
- [docs/agent-sandbox.md](../agent-sandbox.md) — original design note (superseded in part by this ADR set)
