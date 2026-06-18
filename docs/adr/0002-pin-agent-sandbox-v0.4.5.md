# ADR-0002: Pin agent-sandbox v0.4.5 (`v1alpha1`) and use the direct `sandboxTemplateRef` chain

- **Status:** Proposed
- **Date:** 2026-06-18
- **Deciders:** HC Lo (hclo)
- **Depends on:** [ADR-0001](0001-adopt-agent-sandbox-model.md)

## Context

The agent-sandbox API is still evolving and the resource shape changed between
releases. The install script (`scripts/setup-agent-sandbox.sh`) pins
`AGENT_SANDBOX_VERSION=v0.4.5`, and the runc `SandboxTemplate` was validated
against CRD `v0.4.5`.

We verified the actual v0.4.5 CRD by pulling
`releases/download/v0.4.5/extensions.yaml` directly. Findings:

- v0.4.5 serves **`extensions.agents.x-k8s.io/v1alpha1`**.
- `SandboxClaim.spec` **requires `sandboxTemplateRef`** (a `{name}` reference
  **directly** to a `SandboxTemplate`). It also has an optional `warmpool`
  string (default `"default"`), `lifecycle`, `env`, and `additionalPodMetadata`.

The **current upstream docs** describe a later API (`v1beta1`) in which
`SandboxClaim.spec` drops `sandboxTemplateRef` and instead requires
`warmPoolRef` pointing at a `SandboxWarmPool`. That is a different chain
(`SandboxClaim → SandboxWarmPool → SandboxTemplate`) and would not validate
against the v0.4.5 CRD we install.

> An earlier draft of this design incorrectly assumed the `v1beta1`
> (`warmPoolRef`) shape was authoritative. It is not, for the version we pin.
> This ADR records the verified v0.4.5 behaviour.

## Decision

Pin the controller and CRDs to **v0.4.5 (`v1alpha1`)** for this PR series, and
use the **direct `SandboxClaim.spec.sandboxTemplateRef → SandboxTemplate`**
chain. Do not author `v1beta1`/`warmPoolRef` manifests against the v0.4.5
install. Treat the migration to `v1beta1` (warmPoolRef and any related renames)
as a separate, future ADR taken when we deliberately bump the controller.

## Options considered

- **Pin v0.4.5 (chosen):** reproducible, matches the validated CRD, direct
  chain needs no WarmPool for the cold-start path.
- **Track `latest`:** rejected — the `v1alpha1 → v1beta1` claim-schema change
  would break tenant manifests at deploy time on the next upstream release.
- **Author `v1beta1` now:** rejected — the installed CRD is v0.4.5; v1beta1
  manifests would be rejected by the API server.

## Consequences

**Positive**
- Manifests validate against the exact installed CRD; deploys are reproducible.
- The direct chain is simpler — no `SandboxWarmPool` object required on the
  cold-start path.

**Negative / open items**
- We are pinned to an older API and must write a migration ADR before adopting
  newer controller features that only exist in `v1beta1`.
- The v0.4.5 `warmpool` field defaults to `"default"`. **Open item:** confirm a
  `SandboxClaim` cold-starts with no pre-existing `SandboxWarmPool` named
  `default`, versus needing to create one. To be verified during PR #1 deploy
  verification (profile `hclo-mac`, `us-east-1`).

## References

- v0.4.5 CRD: `https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.5/extensions.yaml`
- Current API reference (`v1beta1`, for contrast): https://agent-sandbox.sigs.k8s.io/docs/api/
