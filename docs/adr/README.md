# Architecture Decision Records

This directory records the significant architecture decisions for the
multi-tenant OpenClaw platform sample, using a lightweight
[MADR](https://adr.github.io/madr/)-style format.

Each ADR is immutable once `Accepted`. To change a decision, add a new ADR
that supersedes the old one (note it in both records).

## Status legend

- **Proposed** — under discussion, not yet agreed.
- **Accepted** — agreed and in force.
- **Superseded by ADR-NNNN** — replaced by a later decision.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-adopt-agent-sandbox-model.md) | Adopt the agent-sandbox model for tenant workspace isolation | Accepted |
| [0002](0002-pin-agent-sandbox-v0.4.5.md) | Pin agent-sandbox v0.4.5 (`v1alpha1`) and use the direct `sandboxTemplateRef` chain | Accepted |
| [0003](0003-per-tenant-sandboxtemplate.md) | Render a per-tenant SandboxTemplate to carry ServiceAccount, Secret, PVC, and env | Accepted |
| [0004](0004-defer-hibernation-and-router.md) | Defer hibernation + sandbox-router; PR #1 keeps path-based routing and `operatingMode: Running` | Accepted |
| [0005](0005-phased-delivery.md) | Phased delivery: lifecycle → router/hibernation → gVisor | Accepted |
| [0006](0006-scale-to-zero-strategy.md) | Scale-to-zero strategy: adopt upstream KEP-968 (sandbox-gateway); always-on in PR #1 | Accepted |

> 0001 is the foundation and the format template. 0006 supplements 0002/0004/0005
> with the verified KEP-968 / release-status findings (2026-06-19).
