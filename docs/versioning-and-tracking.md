# Versioning & Tracking Convention

How this sample records where it has been (tags), where it is going
(milestones), and what each work item is about (labels). Applies to both human
contributors and AI agents. Canonical source — AGENTS.md and CONTRIBUTING.md
point here.

## Git tags — delivered states (retrospective)

Each tag marks a coherent, adopter-usable state of the sample. Tags use
`vMAJOR.MINOR.PATCH` and are **retroactive-friendly**: when a phase completes,
tag the merge commit that represents it, even after the fact, so the evolution
line stays complete.

| Tag | Phase |
|-----|-------|
| v0.1.0 | KEDA scale-to-zero era (Deployment-per-tenant + KEDA HTTP add-on) |
| v0.2.0 | agent-sandbox control plane (runc, always-on) |
| v0.3.0 | gVisor runtime tier + enforced NetworkPolicy + scaling guard |

Rules:
- The repo is intentionally in the **`0.x`** range: the architecture is still
  evolving and APIs may change. Do not jump to `1.0.0` until the sample is
  positioned as stable.
- **The repo tag and the Helm `Chart.yaml` version are decoupled by design.**
  The tag tracks *sample evolution milestones*; the chart version tracks *Helm
  package releases*. They will not match (e.g. tag `v0.3.0` ships chart
  `1.4.0`). Any GitHub Release note MUST state this so adopters are not
  confused.
- A GitHub Release SHOULD accompany a tag, with notes that: summarize the
  phase, call out any capability lost or deferred (e.g. v0.2 dropped v0.1's
  scale-to-zero), and note the chart version shipped.

## Milestones — planned direction (prospective)

Milestones group open issues by the next delivery phase. Named
`vMINOR — <theme>`, aligned to the tag line above.

| Milestone | Theme | Contains |
|-----------|-------|----------|
| v0.4 — Upstream alignment | Catch up to current agent-sandbox: v1beta1 migration + cleanup | maintenance-tier issues |
| v0.5 — Cost & scale | Restore idle scale-to-zero, raise the Gateway/ALB tenant ceiling | architecture-evolution issues |

Rules:
- **Milestone (future) and tag (past) never overlap.** Tags let adopters pin;
  milestones let contributors prioritize.
- The dividing line between milestones is **maintenance vs. evolution**: a
  "catch up to current state" phase precedes an "change the architecture"
  phase, and the evolution phase depends on the maintenance phase landing
  first.
- Work that is **blocked on an external upstream release** gets NO milestone
  (a milestone implies we can schedule it). Track it with the
  `upstream-dependency` label instead.
- Use semantic version themes, not dates — this sample has no SLA and a stale
  date-based milestone reads as a broken promise.

## Labels — orthogonal classification

Labels answer "what is this about", independent of tag/milestone.

| Label | Meaning |
|-------|---------|
| `area/runtime` | Sandbox runtime, gVisor, isolation tiers |
| `area/scaling` | Tenant ceilings, Gateway/ALB, capacity |
| `area/security` | NetworkPolicy, IAM, tenant isolation |
| `area/upstream` | Tracks or depends on upstream agent-sandbox |
| `upstream-dependency` | Blocked on an external upstream release/feature |
| `enhancement` / `bug` / `documentation` | Standard type labels |

Rules:
- Every substantive issue gets at least one `area/*` label.
- `upstream-dependency` is a scheduling signal: it means "do not put this on a
  dated milestone; it moves when upstream moves."

## Quick reference for a new work item

1. Open an issue (English, imperative title — see AGENTS.md Conventions).
2. Add `area/*` label(s); add `upstream-dependency` if externally blocked.
3. Assign a milestone **only if we can schedule it** (not upstream-gated).
4. When a phase ships, tag the merge commit `vX.Y.Z` and publish a Release
   note (stating the chart version and any deferred capability).
