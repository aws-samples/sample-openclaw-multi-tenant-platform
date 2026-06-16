# Agent Sandbox Integration

> Status: **design / in progress** (issue [#365](https://github.com/snese/sample-openclaw-multi-tenant-platform/issues/365))
> Tracks adoption of the [kubernetes-sigs/agent-sandbox](https://agent-sandbox.sigs.k8s.io/) model, as packaged by [awslabs/ai-on-eks](https://awslabs.github.io/ai-on-eks/docs/infra/agents/agent-sandbox).

## Why

Today each tenant workspace is a plain `Deployment` isolated only at the namespace + `NetworkPolicy` level. Model-generated code therefore runs with the full host-kernel syscall surface. This document describes adopting the `Sandbox` Custom Resource model to gain:

- A declarative, lifecycle-managed primitive purpose-built for "a long-running, stateful, singleton container with a stable identity" — which is exactly the per-tenant persistent OpenClaw workspace model.
- A kernel isolation tier (gVisor `runsc`) selectable per workload, delivered as a `SandboxTemplate` field rather than a bespoke runtime layer.
- Built-in hibernation + automatic resume on incoming connections, which replaces the per-tenant KEDA HTTP scale-to-zero for the agent tier.

Positioning note: this uses AWS-native + OSS SIG primitives. It deliberately does **not** adopt the NVIDIA OpenShell / NemoClaw stack — OpenShell's headline value (inference-layer credential injection so the agent never sees the API key) is already provided here by Amazon Bedrock + EKS Pod Identity (zero API keys), and NemoClaw is an alpha, host-centric project that would need adapting into a sidecar/DaemonSet.

## Current state (baseline)

| Concern | Today |
|---|---|
| Provisioning | ArgoCD `ApplicationSet`; PostConfirmation Lambda appends a tenant element via the K8s API; one `Application` per tenant syncs `helm/charts/openclaw-platform` |
| Workload | per-tenant `Deployment` (+ Service, HTTPRoute, NetworkPolicy, PVC, ServiceAccount) |
| Isolation | namespace + `NetworkPolicy` (soft); no `runtimeClassName` |
| Scale-to-zero | KEDA HTTP Add-on `HTTPScaledObject`, `scaleTargetRef.kind: Deployment`, min 0 / max 1 on request rate (idle 900s) |
| Nodes | Graviton ARM64 (`t4g`, AL2023_ARM_64); Karpenter NodePool pinned to `arch: arm64` |
| CNI | default VPC CNI (no Cilium) |

## Target architecture

```
ArgoCD ApplicationSet (per tenant)
  └── SandboxClaim  ──►  SandboxTemplate (runc | gvisor)
                          └── Sandbox (singleton pod, stable identity, PVC-backed)
                                ├── hibernate on idle  /  resume on incoming connection
                                └── runtimeClassName selects isolation tier
```

The agent-sandbox controller (`agent-sandbox-system`) reconciles `Sandbox` / `SandboxClaim` / `SandboxTemplate`. The gVisor tier is a `SandboxTemplate` with `runtimeClassName: gvisor`, scheduled onto a gVisor-capable Karpenter NodePool.

## Key design decisions

### KEDA → native hibernation (agent tier)

The `Sandbox` resource is a **singleton** and exposes no `/scale` subresource, so KEDA HTTP cannot target it — and does not need to. The agent-sandbox controller provides native scale-to-zero via **hibernation** (pause on idle) + **automatic resume on incoming network connections**, with state preserved on a PVC. For the agent tier we therefore remove the per-tenant `HTTPScaledObject` and rely on the controller. KEDA may still be used for any platform routing/proxy `Deployment` tier (different layer, no conflict).

### Background-work hazard (must mitigate)

Hibernation resumes on **incoming** connections only. A tenant agent doing background work with no inbound traffic for the idle window risks being hibernated mid-task. Mitigations:

- a lightweight **heartbeat** keepalive so active background work maintains recent incoming activity, and/or
- `shutdownTime` / TTL reset around known long-running windows, and
- PVC-backed state so durable work survives hibernate/resume.

Note: snapshot-based suspend/resume is GKE-specific and **not** available on EKS Standard; on EKS we rely on hibernation-via-network-activity + PVC.

### gVisor on ARM64

gVisor supports ARM64 ("generally supported with exceptions"), so the all-Graviton cluster needs no x86 migration. The gVisor tier requires a Karpenter NodePool whose AL2023 nodes install the `runsc` containerd shim via user-data; the ai-on-eks reference NodePool is x86, so its user-data must be adapted to ARM64.

## Phased delivery

### PR #1 — Sandbox control plane + tenant migration (runc)

1. Install the agent-sandbox controller + CRDs (`scripts/setup-agent-sandbox.sh`, wired into `deploy-all.sh`). _(this PR, additive)_
2. Add a `runc` `SandboxTemplate`.
3. Migrate the per-tenant workload from `Deployment` to `SandboxClaim`.
4. Remove the agent-tier KEDA `HTTPScaledObject`; rely on controller hibernation.
5. Add the heartbeat keepalive.

Runtime stays `runc` so the lifecycle-model change is isolated from the runtime change.

### PR #2 — gVisor runtime tier

1. `gvisor` `RuntimeClass`.
2. gVisor-capable ARM64 Karpenter NodePool (AL2023 + `runsc` shim via user-data).
3. `gvisor` `SandboxTemplate`.
4. Flip the tenant claim to the gVisor template (a single field).

Sequencing constraint: the gVisor NodePool must exist before a `SandboxClaim` references the gVisor template, or the pod cannot schedule.

### Out of scope (future)

FQDN egress enforcement (Cilium `toFQDNs` on Standard EKS, or native `ApplicationNetworkPolicy` `domainNames` on EKS Auto Mode). Requires a CNI decision; Auto Mode does not support gVisor, so the two are mutually exclusive.

## Verification plan

| Layer | How |
|---|---|
| Static | `make lint` (cdk synth, helm lint, shellcheck) + `make test` (jest, lambda) — no cluster |
| Controller | `setup-agent-sandbox.sh` then `kubectl -n agent-sandbox-system get pods` |
| runc claim | apply a `SandboxClaim`, assert the Sandbox pod reaches Ready, exec a Bedrock call |
| Hibernation | leave idle past the window, assert pod scales to 0, then resume on connection and assert state preserved |
| gVisor (PR #2) | assert pod `runtimeClassName=gvisor`, schedule onto the gVisor NodePool, run the Bedrock conformance check |

A live cluster (EKS, or a local kind/k3d for the runc control-plane checks) is required for everything below the static row.

## References

- [Agent Sandbox docs](https://agent-sandbox.sigs.k8s.io/docs/) (overview, lifecycle, installation)
- [awslabs/ai-on-eks — Agent Sandbox on EKS](https://awslabs.github.io/ai-on-eks/docs/infra/agents/agent-sandbox)
- [gVisor ARM64 compatibility](https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/)
