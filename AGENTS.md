# AGENTS.md -- AI Agent Collaboration Guide

> How AI coding agents (Kiro, Claude Code, Cursor, etc.) should work within this codebase.

## Project Overview

Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated OpenClaw workspace powered by Amazon Bedrock. The repo is designed for `aws-samples` -- anyone can clone -> configure -> deploy.

## Architecture at a Glance

```
User -> CloudFront -> Internet-facing ALB (CF-only SG + WAF) -> EKS Pod (per-tenant)
                                                                |
                                                           Amazon Bedrock
```

Tenant lifecycle:
```
Cognito SignUp -> Lambda (post-confirmation) -> Tenant CR
  -> Operator reconciles via SSA:
       Namespace, ArgoCD Application
  -> ArgoCD auto-syncs helm/charts/openclaw-platform:
       Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota,
       PDB, HTTPRoute, TargetGroupConfiguration
  -> Pod + HTTPRoute + NetworkPolicy + scale-to-zero ready
```

Key components:
- `cdk/` -- AWS CDK infrastructure (TypeScript)
- `helm/` -- Helm chart (source of truth for tenant K8s resources, synced by ArgoCD)
- `auth-ui/` -- Auth UI pages (vanilla JS, no framework) -- index.html, admin.html, terms, privacy
- `cdk/lambda/` -- Cognito trigger functions + cost enforcement (Python)
- `operator/` -- Tenant Operator (Rust/kube-rs) -- creates Namespace + ArgoCD Application + ReferenceGrant via SSA
- `scripts/` -- Operational scripts (Bash)
- `docs/` -- Architecture and operations documentation

## Critical Invariants

These MUST be true at all times. Violating any = broken deployment.

1. **`cdk diff` = no differences** -- CDK code must match deployed stack
2. **Zero sensitive data in repo** -- No account IDs, Cognito IDs, domains, ARNs. All via `cdk.json` context (gitignored)
3. **Zero CJK characters** -- All code, comments, docs, issue titles, PR titles, and issue/PR bodies in English
4. **Helm chart is source of truth** -- `helm/charts/openclaw-platform/` is the source of truth for tenant K8s resources, synced by ArgoCD with auto-prune and selfHeal
5. **Cognito triggers survive `update-user-pool`** -- Always include `--lambda-config` in every `update-user-pool` call (omitting it wipes triggers)
6. **Operator + ArgoCD split** -- Operator creates 3 resources via SSA (Namespace, ArgoCD Application, ReferenceGrant). ArgoCD + Helm creates everything else (PVC, SA, Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TGC, KEDA HSO)
7. **Operator stays distroless** -- `operator/Dockerfile` uses `gcr.io/distroless/cc-debian12`. No external binary dependencies (no helm, no aws CLI). All K8s operations via kube-rs API.

## File Relationships

```
cdk/cdk.json.example  <- Template for cdk.json (real values gitignored)
cdk/lib/eks-cluster-stack.ts  <- Main CDK stack, references Lambda code
cdk/lambda/pre-signup/index.py  <- Email domain gate
cdk/lambda/post-confirmation/index.py  <- Tenant provisioning (creates Tenant CR)
cdk/lambda/cost-enforcer/index.py  <- Per-tenant cost enforcement
operator/src/types.rs  <- Tenant CRD definition (TenantSpec, TenantStatus)
operator/src/controller.rs  <- Reconciles Tenant CR -> creates Namespace + ArgoCD Application + ReferenceGrant via SSA
operator/src/resources.rs  <- ensure_namespace, ensure_argocd_app, ensure_reference_grant
operator/yaml/deployment.yaml  <- Operator deployment + RBAC
helm/charts/openclaw-platform/  <- Helm chart synced by ArgoCD (Deployment, Service, ConfigMap, NetworkPolicy, etc.)
setup.sh  <- One-command deployment (sources scripts/lib/preflight.sh + generate-config.sh)
scripts/lib/preflight.sh  <- Pre-flight checks (tools, AWS, cdk.json)
scripts/lib/generate-config.sh  <- Interactive cdk.json generator
scripts/deploy-auth-ui.sh  <- Uploads auth-ui/ to S3, uses sed to inject config
helm/tenants/values-template.yaml  <- Reference tenant Helm values
auth-ui/index.html  <- SPA, config injected by deploy-auth-ui.sh via sed
auth-ui/admin.html  <- Admin dashboard, same sed injection pattern
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
# Cognito triggers are managed by CDK -- no manual script needed
```

### Helm Chart
```bash
# Edit helm/charts/openclaw-platform/templates/*.yaml or values.yaml
helm template test helm/charts/openclaw-platform -f helm/tenants/values-template.yaml  # Dry run
helm lint helm/charts/openclaw-platform/  # Lint check
# Changes auto-deploy via ArgoCD selfHeal -- no manual apply needed.
# ArgoCD syncs with prune + selfHeal enabled.
```

### Auth UI
```bash
# Edit auth-ui/index.html or auth-ui/admin.html
# IMPORTANT: deploy-auth-ui.sh uses sed to inject config
# Patterns like clientId:'' must match exactly (minified, no spaces)
bash scripts/deploy-auth-ui.sh
# Invalidate CloudFront cache after deploy
```

### Lambda Functions
```bash
# Edit cdk/lambda/*/index.py
python3 -m py_compile cdk/lambda/pre-signup/index.py
python3 -m py_compile cdk/lambda/post-confirmation/index.py
python3 -m py_compile cdk/lambda/cost-enforcer/index.py
cd cdk && npx cdk deploy OpenClawEksStack --require-approval broadening
# Cognito triggers managed by CDK CognitoTriggers custom resource
```

### Operator
```bash
cd operator
cargo build --release
cargo clippy -- -D warnings
# Dockerfile is distroless -- do NOT add external binary dependencies
# All K8s operations must use kube-rs API (no Command::new)
# Operator creates: Namespace, ArgoCD Application, ReferenceGrant
# Everything else is managed by ArgoCD + Helm chart
# Image is pre-built via GitHub Actions and published to GHCR
# Customers pull via ECR pull-through cache -- no local build needed
# Only run build-operator.sh if you modify operator/src/
```

## Testing Checklist

Before declaring any change complete:

- [ ] `cd cdk && npx tsc --noEmit` -- CDK compiles
- [ ] `cd cdk && npx cdk synth --no-staging` -- cdk-nag runs (review findings, suppress with rationale if needed)
- [ ] `cd cdk && npx cdk diff` -- Shows expected changes (or no differences)
- [ ] `cd operator && cargo clippy -- -D warnings && cargo test --lib` -- Operator compiles + tests pass
- [ ] `python3 -m py_compile cdk/lambda/pre-signup/index.py` -- Lambda syntax OK
- [ ] `python3 -m py_compile cdk/lambda/post-confirmation/index.py` -- Lambda syntax OK
- [ ] `python3 -m py_compile cdk/lambda/cost-enforcer/index.py` -- Lambda syntax OK
- [ ] `helm lint helm/charts/openclaw-platform/` -- Helm renders
- [ ] No sensitive data: `grep -rn 'AKIA[A-Z0-9]\{16\}' --include="*.ts" --include="*.py" --include="*.sh" --include="*.rs"` = 0 matches
- [ ] No CJK in code files
- [ ] Cognito triggers attached: `aws cognito-idp describe-user-pool --query 'UserPool.LambdaConfig'`

## CI Pipeline

CI runs on every PR (`.github/workflows/ci.yml`). Key design decisions:

- **All GitHub Actions pinned to commit SHA** -- prevents tag poisoning (ref: Trivy supply chain attack, March 2026)
- **`permissions: contents: read`** at workflow level -- least privilege by default
- **`npm ci --ignore-scripts`** in security job -- blocks postinstall hook attacks
- **cdk-nag integrated** -- `AwsSolutionsChecks` runs on every `cdk synth` via `cdk/bin/cdk.ts`
- **PR jobs are fast (~5 min)**, Docker smoke test only on merge to main. Multi-arch image build + push via `operator-build.yml`

## Common Pitfalls

| Pitfall | Cause | Fix |
|---------|-------|-----|
| Cognito triggers disappear | `update-user-pool` without `--lambda-config` | CDK CognitoTriggers custom resource re-attaches on every deploy |
| `deploy-auth-ui.sh` sed fails silently | Spaces in minified JS patterns | Match exact minified format: `clientId:''` not `clientId: ''` |
| CDK deploy rollback | Template literal escaping (`\${this.region}`) | Use `${this.region}` in backtick strings, never escape |
| Namespace stuck in Terminating | TargetGroupBinding finalizer | Recreate ns -> delete TGB -> delete ns |
| Operator binary not found | Dockerfile changed from distroless | Keep `gcr.io/distroless/cc-debian12`, use kube-rs API only |
| ArgoCD sync conflict | Manual kubectl edit conflicts with ArgoCD selfHeal | Never manually edit ArgoCD-managed resources; change Helm chart instead |

## Conventions

- **Issues**: English, imperative verb start, descriptive (e.g., "Add signup rate limit to pre-signup Lambda")
- **PR titles**: English, conventional commit prefix: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- Commit messages: English, imperative mood, prefix with `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- Commit messages: **NEVER** include real domain names, AWS account IDs, ARNs, CloudFront distribution IDs, or any deployment-specific values. Use `example.com`, `123456789012`, etc.
- Run `bash scripts/install-hooks.sh` after clone to enable commit-msg scanning
- Scripts: Bash, `set -euo pipefail`, use `get_output()` helper for CloudFormation outputs
- CDK context: All configurable values in `cdk.json`, template in `cdk.json.example`
- Documentation: English only, Markdown, stored in `docs/`
