# Admin Journey

## Overview

A platform admin deploys, manages, and monitors the OpenClaw multi-tenant platform.

## Initial Deployment (One-Time)

```
1. Configure    → cp cdk.json.example cdk.json (fill 11 context values)
2. Deploy infra → npx cdk deploy (~15-20 min)
3. K8s setup    → setup-keda.sh + setup-cognito.sh + setup-pvc-backup.sh
                   + setup-image-update.sh + setup-usage-tracking.sh
                   + setup-bedrock-latency.sh + setup-coldstart-alarm.sh
                   + setup-audit-logging.sh
4. First tenant → create-tenant.sh alice
5. ALB setup    → post-deploy.sh (VPC Origin, CloudFront #2, Route53, WAF)
6. Auth UI      → deploy-auth-ui.sh
7. ArgoCD       → setup-argocd.sh + setup-argocd-apps.sh
8. Verify       → health-check.sh
```

## User Signup Approval

```
1. Receive SNS email: "New signup: user@company.com"
2. Open AWS Cognito Console → User Pool → Users
3. Find the user (status: UNCONFIRMED) → Click "Confirm user"
4. Post-confirmation Lambda runs automatically:
   a. Creates Secrets Manager secret (gateway token)
   b. Creates EKS Pod Identity Association
   c. Triggers CodeBuild project (helm install)
   d. Sends SES welcome email to user
5. ~2 minutes later, tenant pod is running
```

## Daily Operations

| Task | How | Frequency |
|------|-----|-----------|
| Health check | `./scripts/health-check.sh` | On demand |
| View usage | CloudWatch Dashboard: OpenClaw-Usage | On demand |
| Cost report | `./scripts/usage-report.sh --month YYYY-MM` | Monthly |
| List tenants | `./scripts/admin-list-tenants.sh` | On demand |
| Check alerts | Email (SNS) — pod restart, latency, cold start, budget | Automatic |

## Alerts (Automatic)

| Alert | Trigger | Action |
|-------|---------|--------|
| Pod restart | CloudWatch Alarm: restart count > 0 | Check pod logs |
| Bedrock latency | P95 > 10 seconds | Check model availability |
| Cold start slow | Pod startup > 60 seconds | Check node capacity, image cache |
| Budget 80% | Cost-enforcer Lambda daily check | Notify tenant, consider limit |
| Budget 100% | Cost-enforcer Lambda daily check | Decide: increase budget or restrict |

## Tenant Management

### Create Tenant

```bash
export OPENCLAW_TENANT_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack \
  --query 'Stacks[0].Outputs[?OutputKey==`TenantRoleArn`].OutputValue' --output text)

./scripts/create-tenant.sh alice \
  --display-name "Alice" \
  --emoji "🤖" \
  --skills "weather,gog,news" \
  --budget 100
```

### Delete Tenant

```bash
./scripts/delete-tenant.sh alice
# Prompts: "Type tenant name to confirm"
# Deletes: ArgoCD app → Helm → namespace → Pod Identity → SM secret → values file
```

### Backup / Restore

```bash
./scripts/backup-tenant.sh alice my-backup-bucket
./scripts/restore-tenant.sh alice s3://my-backup-bucket/backups/alice/alice-2026-03-29.tar.gz
```

## GitOps with ArgoCD

ArgoCD is deployed as an EKS Capability (fully managed by AWS).

### Add Tenant via GitOps

1. Run `create-tenant.sh` (creates SM secret + Pod Identity + values file)
2. Git commit + push the values file
3. ArgoCD ApplicationSet detects new file → auto-syncs → creates namespace + pod

### View ArgoCD UI

ArgoCD EKS Capability provides a hosted UI with AWS Identity Center SSO. Access via:

```bash
./scripts/setup-argocd.sh  # Shows UI URL
```

## Platform Upgrade

### OpenClaw Image Update

- CronJob checks GHCR every 6 hours for new tags
- If new version found: `kubectl set image` across all tenants
- Manual: `helm upgrade` per tenant

### CDK Stack Update

```bash
cd cdk && npx cdk deploy
```

### Auth UI Update

```bash
# Edit auth-ui/index.html
./scripts/deploy-auth-ui.sh
```

## Audit

```bash
# One-time setup
./scripts/setup-audit-logging.sh

# Query Bedrock API calls per tenant
# Use Athena in AWS Console or CLI
```

## Automation Summary

| Action | Automated | Manual |
|--------|-----------|--------|
| User signup | ✅ Cognito + Lambda | Admin clicks "Confirm" |
| Tenant provisioning | ✅ Lambda → CodeBuild | — |
| Welcome email | ✅ SES | — |
| Scale to zero | ✅ KEDA (15 min idle) | — |
| Scale up | ✅ KEDA (on request) | — |
| PVC backup | ✅ CronJob (daily) | — |
| Image update check | ✅ CronJob (6h) | Admin reviews |
| Cost budget alert | ✅ Lambda (daily) | Admin decides action |
| Pod restart alert | ✅ CloudWatch → SNS | — |
| Tenant deletion | — | `delete-tenant.sh` |
| Platform deploy | — | `cdk deploy` + scripts |
