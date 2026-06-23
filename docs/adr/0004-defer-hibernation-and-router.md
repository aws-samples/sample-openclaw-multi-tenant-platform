# ADR-0004: Defer hibernation + sandbox-router; PR #1 keeps path-based routing and `operatingMode: Running`

- **Status:** Proposed
- **Date:** 2026-06-18
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0001](0001-adopt-agent-sandbox-model.md), [ADR-0003](0003-per-tenant-sandboxtemplate.md)

## Context

Today scale-to-zero is provided by the **KEDA HTTP add-on**: a per-tenant
`HTTPScaledObject` targets the tenant `Deployment`, scales it 0↔1 on request
rate (idle 900s), and its interceptor holds an inbound request while a
scaled-to-zero tenant starts. Routing is **path-based**:
`claw.example.com/t/<tenant>/` via a Gateway API `HTTPRoute`.

Adopting the Sandbox model (ADR-0001) removes the `Deployment`. A `Sandbox` is a
singleton with no `/scale` subresource, so KEDA HTTP can no longer target it.
The agent-sandbox model offers its own scale-to-zero via **hibernation**
(pause on idle, "automatic resume on incoming network connections") and a
**sandbox-router** for scalable access. We researched both before committing.

Verified findings that change the picture:

1. **sandbox-router is header-based, not path-based.** It routes by an
   `X-Sandbox-ID` (+ namespace/port) HTTP header to
   `<id>.<ns>.svc.cluster.local`. Our contract is path-based (`/t/<tenant>/`),
   sent by browsers/auth-ui. Stock Gateway API cannot easily translate a
   dynamic path segment into a header, so adopting the router changes the
   routing/UX contract — it is not a drop-in addition.
2. **The router does not itself wake a hibernated sandbox.** Its own tests
   assert that an unreachable sandbox returns **502 Bad Gateway**. So the router
   is a reverse proxy, not an activator.
3. **The wake/hibernation mechanism is unverified.** We could not find a doc
   that states whether hibernation *pauses* the pod (endpoint stays, connection
   can trigger resume) or *deletes* it (then who triggers resume?). The
   controller flags we found are concurrency-only; there is **no idle-timeout
   knob**, and `shutdownTime` is a delete-TTL, not idle-hibernate. The cost
   story (scale-to-zero) hinges entirely on this unknown.

## Decision

Split the scale-to-zero redesign out of PR #1.

**PR #1** runs each tenant Sandbox with **`operatingMode: Running`** (always-on,
no hibernation). Routing stays **path-based**: the per-tenant `HTTPRoute`
backend is repointed from the old Deployment Service to the **Sandbox's
controller-created headless Service**. The KEDA `HTTPScaledObject` is **removed**
in PR #1 (it targeted a Deployment that no longer exists and cannot target a
Sandbox); we accept an always-on interim cost posture.

**The sandbox-router, hibernation, and the scale-to-zero replacement are
deferred to PR #1.5**, gated on first resolving (a) the wake mechanism
(pause-vs-delete and what triggers resume — to be answered by reading the
controller source or by empirical test on the verification cluster) and (b) the
path→header routing strategy. Each will be captured in its own ADR.

## Options considered

- **A. PR #1 keeps path routing + `Running`; defer router/hibernation (chosen):**
  isolates the verified, low-risk lifecycle adoption from the unresolved
  scale-to-zero redesign; PR #1 is deploy-verifiable now.
- **B. Adopt sandbox-router + hibernation in PR #1:** rejected — wake mechanism
  unverified, router is header-based vs our path-based, router returns 502 not
  wake; high risk of shipping a broken scale-to-zero.
- **C. Drop scale-to-zero permanently:** rejected — the cost story is a stated
  value of the sample. We defer, we do not abandon it.

## Consequences

**Positive**
- PR #1 is shippable and deploy-verifiable without the unresolved hibernation
  question.
- Routing and UX contract are unchanged for PR #1.

**Negative / interim**
- Tenants run **always-on** in PR #1 → higher idle cost until PR #1.5. If useful,
  a `shutdownTime`/TTL can still bound truly-abandoned workspaces.
- The original framing "hibernation replaces KEDA scale-to-zero" is **not yet
  proven**; PR #1.5 must validate it end-to-end before we claim the cost benefit.

## Resolution (2026-06-18, verified from controller source @ tag v0.4.5)

The pause-vs-delete question is settled by reading
`controllers/sandbox_controller.go` at the v0.4.5 tag:

- v0.4.5 (`v1alpha1`) uses `Sandbox.Spec.Replicas` (0/1); there is **no**
  `operatingMode: Suspended` (that is a later `v1beta1` field).
- When `Replicas == 0` the controller **deletes the pod**
  (`"Deleting Pod because .Spec.Replicas is 0"` → `r.Delete(ctx, pod)`), so the
  Service endpoint disappears. **This is Case B (delete), not pause.**
- There is **no connection-triggered resume** anywhere in the v0.4.5 core or
  SandboxClaim controllers. The "automatic resume on incoming network
  connections" described in the current docs is a later (`v1beta1`) capability,
  not present in v0.4.5.

**Consequence for KEDA:** on v0.4.5, the Sandbox model does **not** replace
KEDA's scale-to-zero at all — it provides isolation + lifecycle + identity only.
Scale-to-zero with wake still requires both an idle scaler and an activator
(KEDA's two roles). The sandbox-router does not wake (returns 502).

**Therefore PR #1 ships always-on (`Replicas=1`, KEDA removed), and the
scale-to-zero path forks into three options for a later decision:**

1. **No scale-to-zero** — accept always-on (simplest).
2. **Custom activator on v0.4.5** — a path-native component that patches
   `Sandbox.Spec.Replicas` 0↔1 on idle/request (we own and maintain it).
3. **Migrate to v1beta1** — gain native hibernation + wake-on-connection, but
   the claim schema changes to `warmPoolRef` (re-do ADR-0002/0003); larger
   migration.

This decision is deferred to its own ADR; it does not block PR #1.

## References

- Sandbox Router README: `https://github.com/kubernetes-sigs/agent-sandbox/blob/main/clients/python/agentic-sandbox-client/sandbox-router/README.md`
- Controller configuration flags: `https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/configuration.md`
- [docs/agent-sandbox.md](../agent-sandbox.md) — original KEDA→hibernation framing (revised by this ADR)
