# AGENTS.md — AI Agent Collaboration Guide

> How AI coding agents (Kiro, Claude Code, Cursor, etc.) should work within this codebase.

## Project Overview

Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated OpenClaw workspace powered by Amazon Bedrock. The repo is designed for `aws-samples` — anyone can clone → configure → deploy.

## Architecture at a Glance

```
User → CloudFront → ALB (internal) → EKS Pod (per-tenant)
                                        ↓
                                   Amazon Bedrock
```

Tenant lifecycle:
```
Cognito SignUp → Lambda (post-confirmation) → Tenant CR
  → Operator reconciles: Namespace, PVC, SA, ArgoCD Application, KEDA HSO
  → ArgoCD syncs Helm chart into tenant namespace
  → Pod + HTTPRoute + NetworkPolicy + scale-to-zero ready
```

Key components:
- `cdk/` — AWS CDK infrastructure (TypeScript)
- `helm/` — Kubernetes manifests (Helm chart)
- `auth-ui/` — Single-page auth UI (vanilla JS, no framework)
- `cdk/lambda/` — Cognito trigger functions (Python)
- `operator/` — Tenant Operator (Rust/kube-rs) — creates K8s primitives + ArgoCD Application
- `scripts/` — Operational scripts (Bash)
- `argocd/` — ArgoCD base config (ApplicationSet deprecated, operator manages Applications)
- `docs/` — Architecture and operations documentation

## Critical Invariants

These MUST be true at all times. Violating any = broken deployment.

1. **`cdk diff` = no differences** — CDK code must match deployed stack
2. **Zero sensitive data in repo** — No account IDs, Cognito IDs, domains, ARNs. All via `cdk.json` context (gitignored)
3. **Zero CJK characters** — All code, comments, docs in English
4. **Helm values-template placeholders** — `{{TENANT}}`, `{{DOMAIN}}`, etc. must match what the operator and ArgoCD Application use
5. **Cognito triggers survive `update-user-pool`** — Always include `--lambda-config` in every `update-user-pool` call (omitting it wipes triggers)
6. **Gateway API + Tenant Operator** — Path-based routing via HTTPRoute + URLRewrite, tenant lifecycle managed by CRD Operator. Helm deployment delegated to ArgoCD via Application CR.
7. **Operator stays distroless** — `operator/Dockerfile` uses `gcr.io/distroless/cc-debian12`. No external binary dependencies (no helm, no aws CLI). All K8s operations via kube-rs API.

## File Relationships

```
cdk/cdk.json.example  ← Template for cdk.json (real values gitignored)
cdk/lib/eks-cluster-stack.ts  ← Main CDK stack, references Lambda code
cdk/lambda/pre-signup/index.py  ← Email domain gate
cdk/lambda/post-confirmation/index.py  ← Tenant provisioning (creates Tenant CR)
operator/src/controller.rs  ← Reconciles Tenant CR → NS, PVC, SA, ArgoCD App, KEDA HSO
operator/yaml/deployment.yaml  ← Operator deployment + RBAC (includes ArgoCD permissions)
scripts/deploy-auth-ui.sh  ← Uploads auth-ui/ to S3, uses sed to inject config
helm/tenants/values-template.yaml  ← Tenant Helm values with {{PLACEHOLDERS}}
auth-ui/index.html  ← SPA, config injected by deploy-auth-ui.sh via sed
```

## How to Make Changes

### CDK (Infrastructure)
```bash
cd cdk
# Edit lib/eks-cluster-stack.ts
npx tsc --noEmit          # Must pass
npx cdk diff              # Review changes
npx cdk deploy OpenClawEksStack --require-approval broadening
# IMPORTANT: re-run after deploy (triggers get wiped)
cd .. && bash scripts/setup-cognito.sh
```

### Helm Chart (Kubernetes)
```bash
# Edit helm/charts/openclaw-platform/templates/*.yaml or values.yaml
helm template test helm/charts/openclaw-platform -f helm/tenants/values-template.yaml  # Dry run
# ArgoCD auto-syncs changes for existing tenants
# Upload chart to S3 for new tenant provisioning:
bash scripts/upload-helm-chart.sh
```

### Auth UI
```bash
# Edit auth-ui/index.html
# IMPORTANT: deploy-auth-ui.sh uses sed to inject config
# Patterns like clientId:'' must match exactly (minified, no spaces)
bash scripts/deploy-auth-ui.sh
# Invalidate CloudFront cache after deploy
```

### Lambda Functions
```bash
# Edit cdk/lambda/*/index.py
python3 -c "compile(open('cdk/lambda/<fn>/index.py').read(), 'x', 'exec')"  # Syntax check
cd cdk && npx cdk deploy OpenClawEksStack --require-approval broadening
bash scripts/setup-cognito.sh  # Re-attach triggers
```

### Operator
```bash
cd operator
cargo build --release
cargo clippy -- -D warnings
# Dockerfile is distroless — do NOT add external binary dependencies
# All K8s operations must use kube-rs API (no Command::new)
```

## Testing Checklist

Before declaring any change complete:

- [ ] `cd cdk && npx tsc --noEmit` — CDK compiles
- [ ] `cd cdk && npx cdk diff` — Shows expected changes (or no differences)
- [ ] `python3 -c "compile(...)"` — Lambda syntax OK
- [ ] `helm template test helm/charts/openclaw-platform` — Helm renders
- [ ] `cd operator && cargo clippy -- -D warnings` — Operator compiles clean
- [ ] No sensitive data: `grep -rn "123456789012\|snese\.net" --include="*.ts" --include="*.py" --include="*.md" --include="*.sh"` = 0 matches (excluding cdk.json)
- [ ] No CJK: `grep -Prn '[\x{4e00}-\x{9fff}]' --include="*.ts" --include="*.py" --include="*.md" --include="*.sh"` = 0 matches
- [ ] Cognito triggers attached: `aws cognito-idp describe-user-pool --query 'UserPool.LambdaConfig'`

## Common Pitfalls

| Pitfall | Cause | Fix |
|---------|-------|-----|
| Cognito triggers disappear | `update-user-pool` without `--lambda-config` | Always run `setup-cognito.sh` after any Cognito change |
| `deploy-auth-ui.sh` sed fails silently | Spaces in minified JS patterns | Match exact minified format: `clientId:''` not `clientId: ''` |
| CDK deploy rollback | Template literal escaping (`\${this.region}`) | Use `${this.region}` in backtick strings, never escape |
| Namespace stuck in Terminating | TargetGroupBinding finalizer | Recreate ns → delete TGB → delete ns |
| Operator binary not found | Dockerfile changed from distroless | Keep `gcr.io/distroless/cc-debian12`, use kube-rs API only |

## Conventions

- Commit messages: English, imperative mood, prefix with `feat:`, `fix:`, `docs:`, `perf:`
- Scripts: Bash, `set -euo pipefail`, use `get_output()` helper for CloudFormation outputs
- CDK context: All configurable values in `cdk.json`, template in `cdk.json.example`
- Documentation: English only, Markdown, stored in `docs/`
