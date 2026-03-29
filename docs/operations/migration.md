# Migration Guide: v1 → v2 (VPC Rebuild)

v2 changes:
- NAT Gateway from 1 → 2 (HA, one per AZ)
- Managed nodegroup from `system` (t3.medium/amd64) → `system-graviton` (t4g.medium/arm64)
- Karpenter NodePool from amd64 → arm64

These changes require a VPC rebuild and cannot be applied in-place.

## Impact

- VPC rebuild → EKS cluster rebuild → all tenant pods disrupted
- EBS PVC data requires manual migration (snapshot → restore)
- ALB, Route53, and CloudFront need reconfiguration
- Estimated downtime: 30-60 minutes

## Migration Steps

### 1. Backup

```bash
# Backup all tenant PVCs
for ns in $(kubectl get ns -l openclaw.dev/tenant -o name); do
  ns=${ns#namespace/}
  kubectl -n "$ns" get pvc -o json > "backup-${ns}-pvc.json"
done

# Snapshot all EBS volumes
./scripts/setup-pvc-backup.sh --now

# Export tenant list
kubectl get ns -l openclaw.dev/tenant -o jsonpath='{.items[*].metadata.labels.openclaw\.dev/tenant}' > tenants.txt

# Backup Cognito user pool (via AWS Console or CLI export)
```

### 2. Record Current Settings

```bash
# Record CDK context
cat cdk/cdk.json

# Record CloudFront distribution IDs
aws cloudfront list-distributions --query 'DistributionList.Items[*].[Id,Origins.Items[0].DomainName]'

# Record Route53 records
aws route53 list-resource-record-sets --hosted-zone-id <zone-id>
```

### 3. Delete Old Stack

```bash
# Delete Kubernetes resources first (avoid orphans)
kubectl delete ingress --all -A
# Wait for ALB to be cleaned up by LB Controller
sleep 60

# Manually clean up VPC Origin + CloudFront #2 (not managed by CDK)
./scripts/cleanup-post-deploy.sh

cd cdk && npx cdk destroy
```

### 4. Deploy New Stack

```bash
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn>
```

The new stack automatically creates:
- VPC with 2 NAT Gateways
- EKS cluster with `system-graviton` nodegroup (t4g.medium/arm64)
- Karpenter with arm64 NodePool

### 5. Restore Kubernetes Configuration

```bash
aws eks update-kubeconfig --region <region> --name openclaw-cluster

./scripts/setup-keda.sh
./scripts/setup-cognito.sh
./scripts/setup-pvc-backup.sh
./scripts/setup-image-update.sh
./scripts/setup-usage-tracking.sh
```

### 6. Restore Tenants

```bash
# Restore EBS volumes from snapshots and rebuild PVCs
# For each tenant:
for tenant in $(cat tenants.txt); do
  ./scripts/create-tenant.sh "$tenant"
  # Manually restore PVC from snapshot (see AWS docs)
done
```

### 7. Rebuild ALB-Related Resources

```bash
# Wait for the first tenant's ALB to be created
kubectl get ingress -A -w

# Rebuild VPC Origin + CloudFront #2 + Route53 + WAF
./scripts/post-deploy.sh
./scripts/deploy-auth-ui.sh
```

### 8. Verify

```bash
./scripts/check-all-tenants.sh
# Confirm each tenant is accessible at https://<tenant>.your-domain.com
```

## Cost Impact

| Item | v1 | v2 |
|------|----|----|
| NAT Gateway | ~$32/mo (1x) | ~$64/mo (2x) |
| EC2 nodegroup | t3.medium | t4g.medium (Graviton, ~20% cheaper) |
| Karpenter spot | amd64 | arm64 (Graviton spot, usually cheaper) |

The extra NAT adds ~$32/mo, but Graviton savings roughly offset it.
