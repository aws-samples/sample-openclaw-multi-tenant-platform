# Admin Guide

## Initial Deployment (One-Time)

```bash
cp cdk/cdk.json.example cdk/cdk.json   # Fill in context values
REGION=us-east-1 bash scripts/deploy-all.sh   # Full automated deployment (~25 min)
```

`deploy-all.sh` runs all steps: CDK bootstrap + deploy, ArgoCD, platform resources, KEDA, CloudFront ALB origin, Route53, and Cognito verification.

## Teardown

```bash
REGION=us-east-1 bash scripts/destroy-all.sh   # Full automated teardown
```

> For manual step-by-step deployment, see `scripts/deploy-all.sh` for the sequence.

## User Signup (Automated)

1. Receive SNS email: "New signup: user@company.com"
2. Post-confirmation AWS Lambda runs automatically:
   a. Creates Secrets Manager secret (gateway token)
   b. Creates Amazon EKS Pod Identity Association
   c. Creates ApplicationSet element -> ApplicationSet generates Applications (NS, PVC, SA, ArgoCD App, KEDA HSO)
   d. ArgoCD syncs Helm chart -> tenant resources created
   e. Sends SES welcome email
3. ~2 minutes later, tenant pod is running

## Daily Operations

| Task | How | Frequency |
|------|-----|----------|
| Health check | `./scripts/health-check.sh` | On demand |
| View usage | CloudWatch Dashboard: OpenClaw-Usage | On demand |
| Cost report | `./scripts/usage-report.sh --month YYYY-MM` | Monthly |
| List tenants | `./scripts/admin-list-tenants.sh` | On demand |
| Check alerts | Email (SNS) | Automatic |

## Tenant Management

### Create Tenant (Manual -- bypasses Amazon Cognito)

`create-tenant.sh` creates a ApplicationSet element directly. ArgoCD then syncs the Helm chart (creates namespace, Deployment, Service, etc.):

```bash
./scripts/create-tenant.sh alice --email alice@example.com
```

This is useful for testing without going through the Amazon Cognito signup flow.

> Note: This only creates the ApplicationSet element. It does NOT create Secrets Manager secrets, Pod Identity Associations, or Amazon Cognito user attributes. For a full recovery (when PostConfirmation AWS Lambda fails), use `provision-tenant.sh` instead.

### Recover Failed Signup

If a user signed up via Amazon Cognito but their workspace didn't appear (PostConfirmation AWS Lambda failed), use `provision-tenant.sh`:

```bash
./scripts/provision-tenant.sh <tenant-id> <email> [cognito-username]
```

This mirrors the full AWS Lambda provisioning flow: Pod Identity, Secrets Manager, Amazon Cognito attributes, ApplicationSet element, and K8s gateway-token Secret. See the script header for prerequisites.

### Delete Tenant

```bash
./scripts/delete-tenant.sh alice
# Deletes: ArgoCD app -> Helm -> namespace -> Pod Identity -> SM secret -> values file
```

### Backup / Restore

```bash
./scripts/backup-tenant.sh alice my-backup-bucket
./scripts/restore-tenant.sh alice s3://my-backup-bucket/backups/alice/alice-2026-03-29.tar.gz
```

## Platform Upgrade

### OpenClaw Image Update

Update `image.tag` in `helm/charts/openclaw-platform/values.yaml`, commit, and push. ArgoCD auto-syncs the change to all tenant deployments.

For per-tenant overrides, set `spec.image.tag` on the ApplicationSet element.

### AWS CDK Stack Update

```bash
cd cdk && npx cdk deploy
```

## Alerts

| Alert | Trigger | Action |
|-------|---------|--------|
| Pod restart | CloudWatch: restart count > 0 | Check pod logs |
| Amazon Bedrock latency | P95 > 10 seconds | Check model availability |
| Cold start slow | Pod startup > 60 seconds | Check node capacity |
| Budget 80% | Cost-enforcer AWS Lambda | Notify tenant |
| Budget 100% | Cost-enforcer AWS Lambda | Decide: increase or restrict |

## Automation Summary

| Action | Automated | Manual |
|--------|-----------|--------|
| User signup | Amazon Cognito + AWS Lambda | -- |
| Tenant provisioning | AWS Lambda -> ApplicationSet element -> ArgoCD -> Helm | -- |
| Welcome email | SES | -- |
| Scale to zero / up | KEDA | -- |
| PVC backup | AWS Backup / on-demand scripts | -- |
| Image update check | CronJob (6h) | Admin reviews |
| Cost budget alert | AWS Lambda (daily) | Admin decides |
| Tenant deletion | -- | `delete-tenant.sh` |
| Platform deploy | -- | `cdk deploy` + scripts |
