# AGENTS.md -- AI Agent Collaboration Guide

> How AI coding agents (Kiro, Claude Code, Cursor, etc.) should work within this codebase.

## Project Overview

Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated OpenClaw workspace powered by Amazon Bedrock. The repo is designed for `aws-samples` -- anyone can clone -> configure -> deploy.

## Architecture at a Glance

```
User -> CloudFront -> Internet-facing ALB (CF-only SG) -> EKS Pod (per-tenant)
                                                                |
                                                           Amazon Bedrock
```

Tenant lifecycle:
```
Cognito SignUp -> Lambda (post-confirmation) -> ApplicationSet element
  -> ApplicationSet generates ArgoCD Applications:
       Per-tenant Application (auto-sync Helm chart)
  -> ArgoCD auto-syncs helm/charts/openclaw-platform:
       Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota,
       PDB, HTTPRoute, TargetGroupConfiguration
  -> Pod + HTTPRoute + NetworkPolicy + scale-to-zero ready
```

Key components:
- `cdk/` -- AWS CDK infrastructure (TypeScript)
- `helm/` -- Helm chart (source of truth for tenant K8s resources, synced by ArgoCD)
- `auth-ui/` -- Auth UI pages (vanilla JS, no framework) -- index.html, admin.html, terms, privacy
- `cdk/lambda/` -- Amazon Cognito trigger functions + cost enforcement (Python)
- `scripts/` -- Operational scripts (Bash)
- `docs/` -- Architecture and operations documentation

## Critical Invariants

These MUST be true at all times. Violating any = broken deployment.

1. **`cdk diff` = no differences** -- AWS CDK code must match deployed stack
2. **Zero sensitive data in repo** -- No account IDs, Amazon Cognito IDs, domains, ARNs. All via `cdk.json` context (gitignored)
3. **Zero CJK characters** -- All code, comments, docs, issue titles, PR titles, and issue/PR bodies in English
4. **Helm chart is source of truth** -- `helm/charts/openclaw-platform/` is the source of truth for tenant K8s resources, synced by ArgoCD with auto-prune and selfHeal
5. **Amazon Cognito triggers survive `update-user-pool`** -- Always include `--lambda-config` in every `update-user-pool` call (omitting it wipes triggers)
6. **ApplicationSet + ArgoCD** -- ApplicationSet generates per-tenant ArgoCD Applications. ArgoCD + Helm creates all tenant resources (Namespace, PVC, SA, Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TGC, KEDA HSO, ReferenceGrant)

## File Relationships

```
cdk/cdk.json.example  <- Template for cdk.json (real values gitignored)
cdk/lib/eks-cluster-stack.ts  <- Main AWS CDK stack, references AWS Lambda code
cdk/lambda/pre-signup/index.py  <- Email domain gate
cdk/lambda/post-confirmation/index.py  <- Tenant provisioning (adds element to ApplicationSet)
cdk/lambda/cost-enforcer/index.py  <- Per-tenant cost enforcement
helm/applicationset.yaml  <- ArgoCD ApplicationSet (multi-tenant generator)
helm/charts/openclaw-platform/  <- Helm chart synced by ArgoCD (Deployment, Service, ConfigMap, NetworkPolicy, etc.)
helm/tenants/values-template.yaml  <- Reference tenant Helm values (for dry-run testing)
helm/gateway.yaml  <- Gateway API resources (GatewayClass + LoadBalancerConfiguration + Gateway)
scripts/deploy-platform.sh  <- Deploys ApplicationSet + Gateway (injects cdk.json values)
scripts/create-tenant.sh  <- Adds tenant to ApplicationSet elements
scripts/delete-tenant.sh  <- Removes tenant from ApplicationSet + cleanup
scripts/provision-tenant.sh  <- Full tenant recovery when PostConfirmation AWS Lambda fails
scripts/setup-argocd.sh  <- ArgoCD via Helm
scripts/setup-keda.sh  <- KEDA + HTTP Add-on
scripts/deploy-auth-ui.sh  <- Uploads auth-ui/ to Amazon S3, uses sed to inject config
scripts/lib/preflight.sh  <- Pre-flight checks (tools, AWS, cdk.json)
scripts/lib/generate-config.sh  <- Interactive cdk.json generator
scripts/lib/common.sh  <- Shared helpers (require_cluster, get_output, log)
setup.sh  <- One-command deployment (sources scripts/lib/preflight.sh + generate-config.sh)
Makefile  <- Aggregate lint/test/validate targets for all components
auth-ui/index.html  <- SPA, config injected by deploy-auth-ui.sh via sed
auth-ui/admin.html  <- Admin dashboard, same sed injection pattern
```


## AWS Service Naming Rules

All prose (docs, comments, HTML, commit messages) must use full AWS service names. CI enforces this via `scripts/check-rubric.sh`.

| Short | Full Name | When to use short |
|-------|-----------|-------------------|
| Bedrock | Amazon Bedrock | Code identifiers, URLs, CLI commands |
| EKS | Amazon EKS | Code identifiers, URLs, CLI commands |
| S3 | Amazon S3 | Code identifiers, URLs, CLI commands |
| EFS | Amazon EFS | Code identifiers, URLs, CLI commands |
| CloudFront | Amazon CloudFront | Code identifiers, URLs, CLI commands |
| Cognito | Amazon Cognito | Code identifiers, URLs, CLI commands |
| Lambda | AWS Lambda | Code identifiers, URLs, CLI commands |
| CDK | AWS CDK | Code identifiers, URLs, CLI commands |
| WAF | AWS WAF | Code identifiers, URLs, CLI commands |

**Examples:**
- ✅ "powered by Amazon Bedrock" (prose)
- ✅ `bedrock:InvokeModel` (code)
- ❌ `"powered by Bedrock"` (prose — missing "Amazon")

**Security claims:** Use "designed to", "configured to", or "by default" qualifiers. Never say "ensures" or "guarantees" without qualification.

**Run before committing:** `bash scripts/check-rubric.sh`

## How to Make Changes

### AWS CDK (Infrastructure)
```bash
cd cdk
# Edit lib/eks-cluster-stack.ts
npx tsc --noEmit          # Must pass
npx cdk diff              # Review changes
npx cdk deploy OpenClawEksStack --require-approval broadening
# IMPORTANT: re-run after deploy (triggers get wiped)
# Amazon Cognito triggers are managed by AWS CDK -- no manual script needed
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
# Invalidate Amazon CloudFront cache after deploy
```

### AWS Lambda Functions
```bash
# Edit cdk/lambda/*/index.py
python3 -m py_compile cdk/lambda/pre-signup/index.py
python3 -m py_compile cdk/lambda/post-confirmation/index.py
python3 -m py_compile cdk/lambda/cost-enforcer/index.py
cd cdk && npx cdk deploy OpenClawEksStack --require-approval broadening
# Cognito triggers managed by AWS CDK CognitoTriggers custom resource
```

```

## Testing Checklist

Before declaring any change complete:

- [ ] `cd cdk && npx tsc --noEmit` -- AWS CDK compiles
- [ ] `cd cdk && npx cdk synth --no-staging` -- cdk-nag runs (review findings, suppress with rationale if needed)
- [ ] `cd cdk && npx cdk diff` -- Shows expected changes (or no differences)
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

## Common Pitfalls

| Pitfall | Cause | Fix |
|---------|-------|-----|
| Cognito triggers disappear | `update-user-pool` without `--lambda-config` | AWS CDK CognitoTriggers custom resource re-attaches on every deploy |
| `deploy-auth-ui.sh` sed fails silently | Spaces in minified JS patterns | Match exact minified format: `clientId:''` not `clientId: ''` |
| AWS CDK deploy rollback | Template literal escaping (`\${this.region}`) | Use `${this.region}` in backtick strings, never escape |
| Namespace stuck in Terminating | TargetGroupBinding finalizer | Recreate ns -> delete TGB -> delete ns |
| ArgoCD sync conflict | Manual kubectl edit conflicts with ArgoCD selfHeal | Never manually edit ArgoCD-managed resources; change Helm chart instead |

## Conventions

- **Issues**: English, imperative verb start, descriptive (e.g., "Add signup rate limit to pre-signup AWS Lambda")
- **PR titles**: English, conventional commit prefix: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- Commit messages: English, imperative mood, prefix with `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- Commit messages: **NEVER** include real domain names, AWS account IDs, ARNs, Amazon CloudFront distribution IDs, or any deployment-specific values. Use `example.com`, `123456789012`, etc.
- Run `bash scripts/install-hooks.sh` after clone to enable commit-msg scanning
- Scripts: Bash, `set -euo pipefail`, use `get_output()` helper for CloudFormation outputs
- CDK context: All configurable values in `cdk.json`, template in `cdk.json.example`
- Documentation: English only, Markdown, stored in `docs/`
