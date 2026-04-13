#!/usr/bin/env bash
# Full teardown — reverse of deploy-all.sh.
#
# Usage:
#   REGION=us-east-1 bash scripts/destroy-all.sh
#
# Order: K8s resources → Helm releases → ALB/ENI cleanup → cdk destroy
# This ensures VPC is clean before CloudFormation attempts subnet deletion.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
CDK_DIR="$REPO_ROOT/cdk"

REGION="${REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
export AWS_REGION="$REGION"

source "$SCRIPTS_DIR/lib/common.sh"

echo "============================================"
echo "  OpenClaw Platform — Full Teardown"
echo "  Region:  $REGION"
echo "  Stack:   $STACK"
echo "============================================"
echo ""
echo "This will DELETE all resources. Press Ctrl+C within 5 seconds to abort."
sleep 5

# ── Step 1: Delete tenants ──────────────────────────────────────────────────
echo "==> Step 1/5: Removing tenants"
if kubectl get applicationset openclaw-tenants -n argocd &>/dev/null; then
  # Clear all tenant elements from ApplicationSet
  kubectl patch applicationset openclaw-tenants -n argocd --type merge \
    -p '{"spec":{"generators":[{"list":{"elements":[]}}]}}' 2>/dev/null || true
  echo "  Cleared ApplicationSet elements. Waiting for ArgoCD to delete tenant namespaces..."
  sleep 15
  # Delete the ApplicationSet itself
  kubectl delete applicationset openclaw-tenants -n argocd --ignore-not-found 2>/dev/null || true
  echo "  ApplicationSet deleted."
else
  echo "  No ApplicationSet found, skipping."
fi
echo ""

# ── Step 2: Delete KEDA ─────────────────────────────────────────────────────
echo "==> Step 2/5: Removing KEDA"
helm uninstall http-add-on -n keda 2>/dev/null && echo "  HTTP add-on removed." || echo "  HTTP add-on not found."
helm uninstall keda -n keda 2>/dev/null && echo "  KEDA removed." || echo "  KEDA not found."
kubectl delete namespace keda --ignore-not-found 2>/dev/null || true
echo ""

# ── Step 3: Delete Gateway (triggers ALB deletion) ──────────────────────────
echo "==> Step 3/5: Removing Gateway API resources"
kubectl delete gateway openclaw-gateway -n openclaw-system --ignore-not-found 2>/dev/null || true
kubectl delete gatewayclass openclaw-alb --ignore-not-found 2>/dev/null || true
echo "  Gateway deleted. Waiting for ALB controller to remove ALB..."

# Wait for ALB to be deleted (up to 3 minutes)
for i in $(seq 1 18); do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?contains(LoadBalancerName,'openclaw')])" --output text 2>/dev/null || echo "0")
  if [ "$ALB_COUNT" = "0" ]; then
    echo "  ALB deleted."
    break
  fi
  if [ "$i" -eq 18 ]; then
    echo "  ALB still exists. Force deleting..."
    for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null); do
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null
    done
  fi
  sleep 10
done

# Clean up target groups
for arn in $(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName,'openclaw')].TargetGroupArn" --output text 2>/dev/null); do
  aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null
done
echo ""

# ── Step 4: Delete ArgoCD ───────────────────────────────────────────────────
echo "==> Step 4/5: Removing ArgoCD"
kubectl delete namespace argocd --ignore-not-found 2>/dev/null || true
kubectl delete namespace openclaw-system --ignore-not-found 2>/dev/null || true
echo "  ArgoCD removed."
echo ""

# ── Step 5: CDK Destroy ────────────────────────────────────────────────────
echo "==> Step 5/5: CDK Destroy"

# Clean Karpenter instance profiles (blocks IAM role deletion)
for profile in $(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'$STACK') || contains(InstanceProfileName,'openclaw-$STACK')].InstanceProfileName" \
  --output text 2>/dev/null); do
  for role in $(aws iam get-instance-profile --instance-profile-name "$profile" \
    --query "InstanceProfile.Roles[*].RoleName" --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null
  done
  aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null && echo "  Deleted instance profile: $profile"
done

# Delete Karpenter NodeClass to trigger instance profile cleanup by Karpenter controller
kubectl delete ec2nodeclass --all --ignore-not-found 2>/dev/null || true
kubectl delete nodepool --all --ignore-not-found 2>/dev/null || true
sleep 5

cd "$CDK_DIR"
if ! cdk destroy --force; then
  echo "  CDK destroy had errors. Cleaning instance profiles and retrying..."
  cd "$REPO_ROOT"
  for profile in $(aws iam list-instance-profiles \
    --query "InstanceProfiles[?contains(InstanceProfileName,'openclaw')].InstanceProfileName" \
    --output text 2>/dev/null); do
    for role in $(aws iam get-instance-profile --instance-profile-name "$profile" \
      --query "InstanceProfile.Roles[*].RoleName" --output text 2>/dev/null); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null
    done
    aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null
  done
  cd "$CDK_DIR"
  cdk destroy --force || aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" --deletion-mode FORCE_DELETE_STACK
fi
cd "$REPO_ROOT"

# Clean up resources created outside CloudFormation

# Log groups (CloudWatch Observability addon)
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/openclaw" \
  --region "$REGION" --query "logGroups[*].logGroupName" --output text 2>/dev/null); do
  aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null && echo "  Deleted log group: $lg"
done

# CloudFront WAFs (created by CDK custom resource in us-east-1, not deleted by CDK destroy)
for wacl_json in $(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query "WebACLs[?contains(Name,'$STACK')].{Id:Id,Name:Name,Lock:LockToken}" --output json 2>/dev/null \
  | python3 -c "import json,sys;[print(f'{w[\"Id\"]}|{w[\"Name\"]}|{w[\"Lock\"]}') for w in json.load(sys.stdin)]" 2>/dev/null); do
  IFS='|' read -r id name lock <<< "$wacl_json"
  aws wafv2 delete-web-acl --name "$name" --scope CLOUDFRONT --id "$id" --lock-token "$lock" --region us-east-1 2>/dev/null && echo "  Deleted WAF: $name"
done

# Karpenter instance profiles (broader match — Karpenter generates unpredictable names)
for profile in $(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'$STACK') || contains(InstanceProfileName,'openclaw')].InstanceProfileName" \
  --output text 2>/dev/null); do
  for role in $(aws iam get-instance-profile --instance-profile-name "$profile" \
    --query "InstanceProfile.Roles[*].RoleName" --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null
  done
  aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null && echo "  Deleted instance profile: $profile"
done

echo ""
echo "============================================"
echo "  Teardown Complete!"
echo "  All resources in $REGION have been removed."
echo ""
echo "  Note: EFS file systems are retained (tenant data protection)."
echo "  To delete: aws efs describe-file-systems --query 'FileSystems[?contains(Name,\`OpenClaw\`)].FileSystemId'"
echo "============================================"
