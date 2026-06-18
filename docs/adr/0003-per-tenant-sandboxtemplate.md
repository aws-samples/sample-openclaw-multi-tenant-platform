# ADR-0003: Render a per-tenant SandboxTemplate to carry ServiceAccount, Secret, PVC, and env

- **Status:** Proposed
- **Date:** 2026-06-18
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0002](0002-pin-agent-sandbox-v0.4.5.md)

## Context

Each tenant's OpenClaw workspace pod needs several **per-tenant, reference-typed**
inputs that the current `Deployment` expresses today:

- a per-tenant **ServiceAccount** for EKS Pod Identity (zero-API-key Bedrock);
- the gateway-token **Secret** `{fullname}-gateway-token` (today via `envFrom.secretRef`);
- **`TENANT_NAMESPACE`** from the downward API (`fieldRef`);
- a per-tenant data **PVC**;
- three initContainers (config, skills, tools — including the IMDS
  `169.254.170.23` Pod Identity patch).

In the pinned v0.4.5 API (ADR-0002), `SandboxClaim.spec.env` is a list of plain
`{name, value}` pairs — it has **no `valueFrom`**, so it cannot inject a Secret,
a downward-API value, or a ServiceAccount. Those constructs only exist inside a
**PodSpec**. The `SandboxTemplate.spec.podTemplate` *is* a full PodSpec and can
express all of them — but a single shared template cannot carry per-tenant
*names* (SA name, secret name, PVC).

The platform already renders per-tenant output through the ArgoCD
`ApplicationSet` + Helm chart, so per-tenant rendering is a path we already own.

## Decision

Render a **per-tenant `SandboxTemplate`** through the existing ApplicationSet /
Helm path (one template per tenant, named for the tenant). The template's
`podTemplate` carries the per-tenant `serviceAccountName`, secret references,
downward-API env, volumes, initContainers, and a `volumeClaimTemplates` entry
for the data PVC. Each tenant's `SandboxClaim` references its own template by
name.

Set **`envVarsInjectionPolicy: Allowed`** on the template (the v0.4.5 default is
`Disallowed`) so that any future claim-level plain env is still accepted.

Consequently we do **not** keep "one shared template per runtime tier". The
runtime tier (runc/gVisor) is selected by a field *within* each per-tenant
template, driven by a Helm value (consistent with ADR-0005).

## Options considered

- **A. Per-tenant SandboxTemplate (chosen):** fits the existing per-tenant Helm
  rendering; carries SA/Secret/PVC/env via a real PodSpec.
- **B. Single shared template + `claim.env`:** rejected — `claim.env` is plain
  `name/value` only; cannot inject the gateway-token Secret, the downward-API
  namespace, or a per-tenant ServiceAccount.
- **C. One template per tier + controller naming-convention magic:** rejected —
  relies on undocumented controller behaviour for per-tenant SA/secret binding;
  high risk.

## Consequences

**Positive**
- Per-tenant SA (Pod Identity), Secret, PVC, and env are all expressible.
- Reuses the existing ApplicationSet render-per-tenant mechanism; little new
  machinery.

**Negative / open items**
- More `SandboxTemplate` objects (one per tenant) instead of one per tier.
  Acceptable at this sample's tenant scale; revisit for very large fleets
  (a pool model is the large-scale variant).
- The gVisor tier (ADR-0005) becomes a Helm value flipping `runtimeClassName`
  in the per-tenant template, rather than a second shared template.
- agent-sandbox's secure default sets `automountServiceAccountToken: false`.
  **Open item:** confirm Pod Identity still works (it relies on the Pod Identity
  Agent + webhook, not the SA token mount). Verify during PR #1 deploy
  verification.

## References

- v0.4.5 `SandboxClaim` / `SandboxTemplate` schema — see [ADR-0002](0002-pin-agent-sandbox-v0.4.5.md)
- [docs/agent-sandbox.md](../agent-sandbox.md)
