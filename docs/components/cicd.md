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

1. Post-Confirmation Lambda creates a Tenant CR
2. Operator reconciles: creates Namespace, PVC, ServiceAccount, ArgoCD Application, KEDA HSO
3. ArgoCD syncs the Helm chart: creates Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration

For manual provisioning without Cognito, `create-tenant.sh` uses `helm install` directly (bypasses ArgoCD).

## Image Update CronJob

`scripts/image-update-cronjob.yaml` -- checks GHCR for new OpenClaw images every 6 hours.

1. Gets current image tag from any tenant deployment
2. Queries GHCR tag list API
3. If newer semver tag found, runs `kubectl set image` across all tenant deployments

> Note: CronJob updates running deployments but does NOT update values in git. For ArgoCD-managed tenants, ArgoCD may revert the image change on next sync.

**Manual trigger:**

```bash
kubectl create job --from=cronjob/openclaw-image-updater manual-update -n kube-system
```

## Auth UI Deployment

```bash
./scripts/deploy-auth-ui.sh us-west-2
```

Reads CDK stack outputs, injects config into `auth-ui/*.html`, syncs to S3.

## Audit Logging

```bash
./scripts/setup-audit-logging.sh us-west-2
```

Sets up CloudTrail + S3 + Athena for Bedrock API audit.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | GitHub Actions CI pipeline |
| `scripts/image-update-cronjob.yaml` | Image update CronJob manifest |
| `scripts/deploy-auth-ui.sh` | S3 + CloudFront auth UI deployment |
| `scripts/setup-audit-logging.sh` | CloudTrail + S3 + Athena setup |
