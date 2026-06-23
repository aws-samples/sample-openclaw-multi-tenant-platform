# ADR-0006: Scale-to-zero strategy — adopt upstream KEP-968 (sandbox-gateway); ship always-on in PR #1

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0001](0001-adopt-agent-sandbox-model.md), [ADR-0004](0004-defer-hibernation-and-router.md), [ADR-0005](0005-phased-delivery.md)

## Context

ADR-0004 left an open item: how to achieve idle→0 + wake-on-traffic on the
Sandbox model. Two things were then verified from source and upstream.

**1. Suspend = pod termination, with no built-in idle/wake (verified from controller source).**
In both v0.4.5 (`Spec.Replicas==0`) and v1beta1 (`operatingMode: Suspended`) the
controller **deletes the pod**; there is no idle detection and no
connection-triggered resume in the controller. So the Sandbox model alone does
**not** replace KEDA's two active roles (idle-detect + request-holding activator).

**2. Upstream is actively building exactly this — KEP-968.**
[KEP-968 "Intelligent Auto-Suspend and Resume"](https://github.com/kubernetes-sigs/agent-sandbox/pull/972)
(by janetkuo; a competing OpenClaw-named variant is [#970](https://github.com/kubernetes-sigs/agent-sandbox/pull/970)) introduces:
- `AutoSuspendPolicy` in the **v1beta1** `SandboxSpec` (idle-detection strategies, scheduled wakeup);
- a centralized Go **`sandbox-gateway`** that **buffers** an incoming request, patches
  `operatingMode=Running`, waits for the resumed pod's HTTP **registration ping**,
  then **flushes the buffered request** — transparent wake with zero dropped
  connections. This covers the **browser / web-UI access pattern** directly (no
  SDK-explicit-resume required), which was our exact open concern;
- `SandboxWarmPool` integration for sub-second thaw.

Our multi-tenant OpenClaw/Hermes use case is literally KEP-968's motivating
"Claw-like" scenario.

**3. Release status (verified).** Latest stable release is **v0.4.6** (v1alpha1);
**v0.5.0rc1** is a prerelease; `AutoSuspendPolicy` is an **unmerged KEP, not in any
release**. Therefore scale-to-zero with transparent wake **cannot be built on a
stable API today**.

## Decision

- **PR #1 ships always-on** (`Running`) on the **v0.4.x stable line** (stay on the
  validated v0.4.5; v0.4.6 is available), v1alpha1, direct `sandboxTemplateRef`
  (ADR-0002/0003). KEDA `HTTPScaledObject` is removed.
- **Scale-to-zero is deferred and will adopt the upstream KEP-968 path**
  (`sandbox-gateway` + `AutoSuspendPolicy`) once it lands in a stable v1beta1
  release. We will **not** build a throwaway activator.
- If scale-to-zero is required before KEP-968 ships, build a **minimal interim
  gateway that mirrors the KEP buffer-and-resume contract** (forward-compatible,
  replaceable) — not KEDA-on-Sandbox.
- The v1alpha1→v1beta1 migration (`sandboxTemplateRef`→`warmPoolRef` +
  `AutoSuspendPolicy`) is an accepted future cost; it cannot be pre-empted because
  the target API is unreleased.

## Options considered

- **KEDA on Sandbox:** rejected — a Sandbox exposes no `/scale` subresource for
  KEDA to target, KEDA's interceptor cannot drive `operatingMode`, and it
  contradicts adopting the Sandbox model.
- **Custom throwaway activator now:** rejected — duplicates KEP-968.
- **Adopt upstream KEP-968 when released (chosen)**, with an optional
  forward-compatible interim gateway if scale-to-zero is needed sooner.

## Consequences

**Positive**
- Aligned with the upstream direction; our use case is KEP-968's exact target.
- PR #1 is unblocked and ships on a stable API.
- High-leverage field contribution: comment on KEP-968 (#972/#970) with our
  multi-tenant + web-UI transparent-wake + gVisor requirements; register on
  [#776](https://github.com/kubernetes-sigs/agent-sandbox/issues/776).

**Negative / interim**
- No scale-to-zero until KEP-968 ships (or we build the interim gateway).
  Interim posture is always-on; bound abandoned workspaces with `shutdownTime`/TTL
  if cost requires.
- A future v1beta1 migration is required to use `AutoSuspendPolicy`.

## References

- KEP-968: https://github.com/kubernetes-sigs/agent-sandbox/pull/972 (+ #970)
- Roadmap (Auto Suspend/Resume, Scale to Zero, 1st Class Router — all Planned):
  `https://github.com/kubernetes-sigs/agent-sandbox/blob/main/roadmap.md`
- Controller suspend=delete evidence — see [ADR-0004](0004-defer-hibernation-and-router.md) Resolution.
