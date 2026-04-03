# CI/CD and Automation

## GitHub Actions CI

Defined in `.github/workflows/ci.yml`. Runs on push/PR to `main`.

| Step | What It Does |
|---|---|
| TypeScript compile check | `npx tsc --noEmit` in `cdk/` |
| CDK synth | `npx cdk synth --no-staging` -- validates CloudFormation templates |
| Helm lint | `helm lint helm/charts/openclaw-platform/` with test values |
| Shell script syntax | `bash -n` on every `scripts/*.sh` |
| Sensitive data scan | Greps for known account IDs, domains, Cognito pool IDs |
| CJK characters check | Fails if any CJK characters found (English-only repo) |

## Tenant Provisioning

Tenant provisioning uses ArgoCD:

1. Post-Confirmation Lambda creates a ApplicationSet element
2. ApplicationSet generates Applications: creates Namespace, PVC, ServiceAccount, ArgoCD Application, KEDA HSO
3. ArgoCD syncs the Helm chart: creates Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration

For manual provisioning without Cognito, `create-tenant.sh` creates a ApplicationSet element directly (Operator + ArgoCD handle the rest).

## Image Upgrade

To upgrade the OpenClaw image across all tenants, update the Helm chart values:

1. Change `image.tag` in `helm/charts/openclaw-platform/values.yaml`
2. Commit and push to the main branch
3. ArgoCD auto-syncs the change to all tenant deployments

For per-tenant image overrides, set `spec.image.tag` on the ApplicationSet element (see `examples/tenant.yaml`).

> **Why not `kubectl set image`?** ArgoCD `selfHeal: true` reverts any live mutation within seconds. The Helm chart is the single source of truth for deployments.

## Auth UI Deployment

```bash
./scripts/deploy-auth-ui.sh us-west-2
```

Reads CDK stack outputs, injects config into `auth-ui/*.html`, syncs to S3.

## Audit Logging

```bash
# Audit logging is managed by CDK -- no manual script needed
```

Sets up CloudTrail + S3 + Athena for Bedrock API audit.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | GitHub Actions CI pipeline |
| `helm/charts/openclaw-platform/values.yaml` | Image tag and chart defaults |
| `scripts/deploy-auth-ui.sh` | S3 + CloudFront auth UI deployment |
