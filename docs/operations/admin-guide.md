# Admin Guide

## Initial Deployment (One-Time)

```
1. Configure    -> cp cdk.json.example cdk.json (fill context values)
2. Deploy infra -> npx cdk deploy (~15-20 min)
3. ArgoCD       -> bash scripts/setup-argocd.sh (Helm)
4. Platform     -> bash scripts/deploy-platform.sh (ApplicationSet + Gateway)
5. KEDA         -> bash scripts/setup-keda.sh
6. First tenant -> scripts/create-tenant.sh alice
7. ALB setup    -> scripts/post-deploy.sh (CloudFront #2, Route53, WAF)
8. Auth UI      -> scripts/deploy-auth-ui.sh
9. Verify       -> scripts/health-check.sh
```

> **Note**: ArgoCD installed via Helm (`scripts/setup-argocd.sh`). For production, consider EKS Capability.

## User Signup (Automated)

1. Receive SNS email: "New signup: user@company.com"
2. Post-confirmation Lambda runs automatically:
   a. Creates Secrets Manager secret (gateway token)
   b. Creates EKS Pod Identity Association
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

### Create Tenant (Manual -- bypasses Cognito)

`create-tenant.sh` creates a ApplicationSet element directly. ArgoCD then syncs the Helm chart (creates namespace, Deployment, Service, etc.):

```bash
./scripts/create-tenant.sh alice --email alice@example.com
```

This is useful for testing without going through the Cognito signup flow.

> Note: This only creates the ApplicationSet element. It does NOT create Secrets Manager secrets, Pod Identity Associations, or Cognito user attributes. For a full recovery (when PostConfirmation Lambda fails), use `provision-tenant.sh` instead.

### Recover Failed Signup

If a user signed up via Cognito but their workspace didn't appear (PostConfirmation Lambda failed), use `provision-tenant.sh`:

```bash
./scripts/provision-tenant.sh <tenant-id> <email> [cognito-username]
```

This mirrors the full Lambda provisioning flow: Pod Identity, Secrets Manager, Cognito attributes, ApplicationSet element, and K8s gateway-token Secret. See the script header for prerequisites.

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

### CDK Stack Update

```bash
cd cdk && npx cdk deploy
```

## Alerts

| Alert | Trigger | Action |
|-------|---------|--------|
| Pod restart | CloudWatch: restart count > 0 | Check pod logs |
| Bedrock latency | P95 > 10 seconds | Check model availability |
| Cold start slow | Pod startup > 60 seconds | Check node capacity |
| Budget 80% | Cost-enforcer Lambda | Notify tenant |
| Budget 100% | Cost-enforcer Lambda | Decide: increase or restrict |

## Automation Summary

| Action | Automated | Manual |
|--------|-----------|--------|
| User signup | Cognito + Lambda | -- |
| Tenant provisioning | Lambda -> ApplicationSet element -> ArgoCD -> Helm | -- |
| Welcome email | SES | -- |
| Scale to zero / up | KEDA | -- |
| PVC backup | AWS Backup / on-demand scripts | -- |
| Image update check | CronJob (6h) | Admin reviews |
| Cost budget alert | Lambda (daily) | Admin decides |
| Tenant deletion | -- | `delete-tenant.sh` |
| Platform deploy | -- | `cdk deploy` + scripts |
