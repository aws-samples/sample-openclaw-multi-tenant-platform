# CI/CD and Automation

## GitHub Actions CI

Defined in `.github/workflows/ci.yml`. Runs on push/PR to `main`.

### Pipeline Steps

| Step | What It Does |
|---|---|
| TypeScript compile check | `npx tsc --noEmit` in `cdk/` |
| CDK synth | `npx cdk synth --no-staging` — validates CloudFormation templates |
| Helm lint | `helm lint helm/charts/openclaw-platform/` with test values |
| Shell script syntax | `bash -n` on every `scripts/*.sh` |
| Sensitive data scan | Greps for known account IDs, domains, Cognito pool IDs, client IDs across `*.ts`, `*.py`, `*.md`, `*.sh`, `*.html`, `*.yaml` |
| CJK characters check | Python script scans all files for Unicode range `\u4e00`–`\u9fff`; fails if any found (English-only repo) |

### Sensitive Data Patterns

The CI checks for hardcoded values matching:
- AWS account ID
- Domain name
- Cognito User Pool ID
- Cognito Client ID

Excludes: `node_modules`, `cdk.out`, `.git/`, `cdk.json`.

## CodeBuild: Tenant Builder

`openclaw-tenant-builder` — a CodeBuild project that runs `helm install` for a new tenant. Triggered by the Post-Confirmation Lambda when a user signs up.

### Flow

```
User signs up → Cognito → Post-Confirmation Lambda
                            → Creates Secrets Manager secret
                            → Creates Pod Identity association
                            → Starts CodeBuild build (TENANT_NAME env var)
```

### Build Steps

1. Install `kubectl` (v1.32) and `helm`
2. `aws eks update-kubeconfig` for the cluster
3. `helm install openclaw-<tenant> helm/charts/openclaw-platform` with:
   - `--namespace openclaw-<tenant> --create-namespace`
   - `--set tenant.name=<tenant>`
   - `--set ingress.enabled=true`
   - `--set scaleToZero.enabled=true`
   - `--wait --timeout 180s`

### IAM

- CodeBuild role has `eks:DescribeCluster` permission
- Mapped to `system:masters` in `aws-auth` ConfigMap (username: `codebuild-tenant-builder`)
- Source: GitHub repo (`main` branch)

## Image Update CronJob

`scripts/image-update-cronjob.yaml` — a Kubernetes CronJob that checks GHCR for new OpenClaw images every 6 hours.

### How It Works

1. Gets current image tag from any `openclaw-helm` deployment
2. Queries GHCR tag list API (`ghcr.io/v2/openclaw/openclaw/tags/list`)
3. Finds the latest semver tag (pattern: `YYYY.*`)
4. If newer, runs `kubectl set image` across all tenant deployments

### Resources

- **Schedule:** `0 */6 * * *` (every 6 hours)
- **Namespace:** `kube-system`
- **ServiceAccount:** `image-updater` with ClusterRole to get/list/patch deployments
- **Image:** `bitnami/kubectl:latest`

### Manual Trigger

```bash
kubectl create job --from=cronjob/openclaw-image-updater manual-update -n kube-system
```

### Install

```bash
./scripts/setup-image-update.sh
```

## Auth UI Deployment

`scripts/deploy-auth-ui.sh` — deploys the Cognito-hosted auth UI to S3 + CloudFront.

### What It Does

1. Reads CloudFormation stack outputs: S3 bucket, Cognito Pool ID, Client ID, domain, CloudFront distribution
2. Injects config values into `auth-ui/*.html` files via `sed`
3. Optionally injects Cloudflare Turnstile site key (`TURNSTILE_SITE_KEY` env var)
4. `aws s3 sync` to the auth UI bucket with `--delete`

```bash
./scripts/deploy-auth-ui.sh us-west-2
```

CloudFront invalidation is handled by the S3 sync + distribution config.

## Audit Logging

`scripts/setup-audit-logging.sh` — sets up CloudTrail + S3 + Athena for Bedrock API audit.

### Components

| Component | Resource | Purpose |
|---|---|---|
| S3 bucket | `openclaw-audit-logs-<ACCOUNT>-<REGION>` | CloudTrail log storage |
| CloudTrail | `openclaw-bedrock-audit` | Captures Bedrock management events |
| Athena DB | `openclaw_audit` | Query interface |
| Athena table | `cloudtrail_bedrock` | External table over CloudTrail JSON |

### CloudTrail Event Selectors

Advanced event selectors filter to Bedrock only:

```json
{
  "Name": "BedrockEvents",
  "FieldSelectors": [
    {"Field": "eventCategory", "Equals": ["Management"]},
    {"Field": "eventSource", "Equals": ["bedrock.amazonaws.com", "bedrock-runtime.amazonaws.com"]}
  ]
}
```

### Example Athena Query

```sql
SELECT eventtime, eventname, useridentity.arn
FROM openclaw_audit.cloudtrail_bedrock
WHERE eventsource = 'bedrock-runtime.amazonaws.com'
ORDER BY eventtime DESC LIMIT 20;
```

### Setup

```bash
./scripts/setup-audit-logging.sh us-west-2
```

## Files

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | GitHub Actions CI pipeline |
| `scripts/image-update-cronjob.yaml` | Image update CronJob manifest |
| `scripts/setup-image-update.sh` | Install image update CronJob |
| `scripts/deploy-auth-ui.sh` | S3 + CloudFront auth UI deployment |
| `scripts/setup-audit-logging.sh` | CloudTrail + S3 + Athena setup |
