# Admin Guide

## Initial Deployment (One-Time)

```
1. Configure    -> cp cdk.json.example cdk.json (fill context values)
2. Deploy infra -> npx cdk deploy (~15-20 min)
3. K8s setup    -> setup-keda.sh
4. Gateway API  -> kubectl apply -f helm/gateway.yaml
5. First tenant -> create-tenant.sh alice
6. ALB setup    -> post-deploy.sh (CloudFront #2, Route53, WAF)
7. Auth UI      -> deploy-auth-ui.sh
8. ArgoCD       -> setup-argocd.sh + setup-argocd-apps.sh
9. Verify       -> health-check.sh
```

## User Signup (Automated)

1. Receive SNS email: "New signup: user@company.com"
2. Post-confirmation Lambda runs automatically:
   a. Creates Secrets Manager secret (gateway token)
   b. Creates EKS Pod Identity Association
   c. Creates Tenant CR -> Operator reconciles (NS, PVC, SA, ArgoCD App, KEDA HSO)
   d. ArgoCD syncs Helm chart -> tenant resources created
   e. Sends SES welcome email
3. ~2 minutes later, tenant pod is running

## Daily Operations

| Task | How | Frequency |
|------|-----|-----------|
| Health check | `./scripts/health-check.sh` | On demand |
| View usage | CloudWatch Dashboard: OpenClaw-Usage | On demand |
| Cost report | `./scripts/usage-report.sh --month YYYY-MM` | Monthly |
| List tenants | `./scripts/admin-list-tenants.sh` | On demand |
| Check alerts | Email (SNS) | Automatic |

## Tenant Management

### Create Tenant (Manual -- bypasses Cognito)

`create-tenant.sh` provisions a tenant using `helm install` directly (not via Tenant CR / ArgoCD):

```bash
export OPENCLAW_TENANT_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query 'Stacks[0].Outputs[?OutputKey==`TenantRoleArn`].OutputValue' --output text)

./scripts/create-tenant.sh alice \
  --display-name "Alice" \
  --skills "weather,gog" \
  --budget 100
```

What it does:
1. Generates tenant values file from template
2. Creates Secrets Manager secret + Pod Identity Association
3. Creates K8s namespace + gateway-token Secret
4. `helm install` with tenant values
5. Waits for pod Ready

> Note: Tenants created via `create-tenant.sh` are NOT managed by ArgoCD. For ArgoCD-managed tenants, use the Cognito signup flow (which creates a Tenant CR -> Operator -> ArgoCD).

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

For per-tenant overrides, set `spec.image.tag` on the Tenant CR.

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
| Tenant provisioning | Lambda -> Tenant CR -> Operator -> ArgoCD | -- |
| Welcome email | SES | -- |
| Scale to zero / up | KEDA | -- |
| PVC backup | CronJob (daily) | -- |
| Image update check | CronJob (6h) | Admin reviews |
| Cost budget alert | Lambda (daily) | Admin decides |
| Tenant deletion | -- | `delete-tenant.sh` |
| Platform deploy | -- | `cdk deploy` + scripts |
