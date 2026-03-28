# Migration Guide: v1 → v2 (VPC 重建)

v2 變更：
- NAT Gateway 從 1 → 2（HA，每個 AZ 一個）
- Managed nodegroup 從 `system` (t3.medium/amd64) → `system-graviton` (t4g.medium/arm64)
- Karpenter NodePool 從 amd64 → arm64

這些變更需要 VPC 重建，無法 in-place 套用。

## 影響範圍

- VPC 重建 → EKS cluster 重建 → 所有 tenant pod 中斷
- EBS PVC 資料需要手動遷移（snapshot → restore）
- ALB、Route53、CloudFront 需要重新設定
- 預估停機時間：30-60 分鐘

## 遷移步驟

### 1. 備份

```bash
# 備份所有 tenant PVC
for ns in $(kubectl get ns -l openclaw.dev/tenant -o name); do
  ns=${ns#namespace/}
  kubectl -n "$ns" get pvc -o json > "backup-${ns}-pvc.json"
done

# 對所有 EBS volume 建 snapshot
./scripts/setup-pvc-backup.sh --now

# 匯出 tenant 清單
kubectl get ns -l openclaw.dev/tenant -o jsonpath='{.items[*].metadata.labels.openclaw\.dev/tenant}' > tenants.txt

# 備份 Cognito user pool（透過 AWS Console 或 CLI export）
```

### 2. 記錄現有設定

```bash
# 記錄 CDK context
cat cdk/cdk.json

# 記錄 CloudFront distribution ID
aws cloudfront list-distributions --query 'DistributionList.Items[*].[Id,Origins.Items[0].DomainName]'

# 記錄 Route53 records
aws route53 list-resource-record-sets --hosted-zone-id <zone-id>
```

### 3. 刪除舊 stack

```bash
# 先刪除 Kubernetes 資源（避免 orphan）
kubectl delete ingress --all -A
# 等 ALB 被 LB Controller 清除
sleep 60

# 手動清除 VPC Origin + CloudFront #2（CDK 不管理）
./scripts/cleanup-post-deploy.sh

cd cdk && npx cdk destroy
```

### 4. 部署新 stack

```bash
npx cdk deploy -c ssoRoleArn=<your-sso-role-arn>
```

新 stack 會自動建立：
- VPC with 2 NAT Gateways
- EKS cluster with `system-graviton` nodegroup (t4g.medium/arm64)
- Karpenter with arm64 NodePool

### 5. 還原 Kubernetes 設定

```bash
aws eks update-kubeconfig --region <region> --name openclaw-cluster

./scripts/setup-keda.sh
./scripts/setup-cognito.sh
./scripts/setup-pvc-backup.sh
./scripts/setup-image-update.sh
./scripts/setup-usage-tracking.sh
```

### 6. 還原 tenant

```bash
# 從 snapshot 還原 EBS volume 並重建 PVC
# 每個 tenant 需要：
for tenant in $(cat tenants.txt); do
  ./scripts/create-tenant.sh "$tenant"
  # 手動 restore PVC from snapshot（參考 AWS 文件）
done
```

### 7. 重建 ALB 相關資源

```bash
# 等第一個 tenant 的 ALB 建立完成
kubectl get ingress -A -w

# 重建 VPC Origin + CloudFront #2 + Route53 + WAF
./scripts/post-deploy.sh
./scripts/deploy-auth-ui.sh
```

### 8. 驗證

```bash
./scripts/check-all-tenants.sh
# 確認每個 tenant 可以透過 https://<tenant>.your-domain.com 存取
```

## 成本影響

| 項目 | v1 | v2 |
|------|----|----|
| NAT Gateway | ~$32/mo (1x) | ~$64/mo (2x) |
| EC2 nodegroup | t3.medium | t4g.medium（Graviton，便宜 ~20%） |
| Karpenter spot | amd64 | arm64（Graviton spot，通常更便宜） |

NAT 多一個約 +$32/mo，但 Graviton 省的錢大致抵消。
