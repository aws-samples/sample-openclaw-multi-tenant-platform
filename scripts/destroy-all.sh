#!/usr/bin/env bash
# Full teardown — reverse of deploy-all.sh.
#
# Usage:
#   REGION=us-east-1 bash scripts/destroy-all.sh
#
# Design: clean ALL non-CloudFormation resources BEFORE cdk destroy,
# so CloudFormation never encounters blocking dependencies.
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

# ── Step 1: Remove K8s workloads ────────────────────────────────────────────
echo "==> Step 1/4: Removing K8s workloads"

# Tenants
if kubectl get applicationset openclaw-tenants -n argocd &>/dev/null; then
  kubectl patch applicationset openclaw-tenants -n argocd --type merge \
    -p '{"spec":{"generators":[{"list":{"elements":[]}}]}}' 2>/dev/null || true
  echo "  Cleared tenants. Waiting for namespace cleanup..."
  sleep 15
  kubectl delete applicationset openclaw-tenants -n argocd --ignore-not-found 2>/dev/null || true
fi

# Karpenter (must delete NodeClass before nodes, so instance profiles get cleaned)
kubectl delete nodepool --all --ignore-not-found 2>/dev/null || true
kubectl delete ec2nodeclass --all --ignore-not-found 2>/dev/null || true
sleep 5

# KEDA
helm uninstall http-add-on -n keda 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true

# Gateway (triggers ALB controller to delete ALB)
kubectl delete gateway openclaw-gateway -n openclaw-system --ignore-not-found 2>/dev/null || true
kubectl delete gatewayclass openclaw-alb --ignore-not-found 2>/dev/null || true

# ArgoCD + namespaces
kubectl delete namespace argocd keda openclaw-system --ignore-not-found 2>/dev/null || true
echo "  K8s workloads removed."
echo ""

# ── Step 2: Clean non-CloudFormation AWS resources ──────────────────────────
echo "==> Step 2/4: Cleaning AWS resources not managed by CloudFormation"

# Wait for ALB deletion (triggered by Gateway delete above)
echo "  Waiting for ALB deletion..."
for i in $(seq 1 18); do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?contains(LoadBalancerName,'openclaw')])" --output text 2>/dev/null || echo "0")
  [ "$ALB_COUNT" = "0" ] && echo "  ALB deleted." && break
  if [ "$i" -eq 18 ]; then
    echo "  Force deleting ALB..."
    for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null); do
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null
    done
  fi
  sleep 10
done

# Target groups
for arn in $(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName,'openclaw')].TargetGroupArn" --output text 2>/dev/null); do
  aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null && echo "  Deleted target group"
done

# Instance profiles (Karpenter creates these at runtime)
for profile in $(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'openclaw') || contains(InstanceProfileName,'$STACK')].InstanceProfileName" \
  --output text 2>/dev/null); do
  for role in $(aws iam get-instance-profile --instance-profile-name "$profile" \
    --query "InstanceProfile.Roles[*].RoleName" --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null
  done
  aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null && echo "  Deleted instance profile: $profile"
done

# VPC endpoints (their ENIs block subnet/VPC deletion)
VPC_ID=$(aws cloudformation list-stack-resources --stack-name "$STACK" --region "$REGION" \
  --query "StackResourceSummaries[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" --output text 2>/dev/null)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  Cleaning VPC $VPC_ID..."
  for vpce in $(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "VpcEndpoints[*].VpcEndpointId" --output text 2>/dev/null); do
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vpce" --region "$REGION" 2>/dev/null && echo "  Deleted VPC endpoint: $vpce"
  done
  # Poll until all ENIs are detached (max 60 seconds)
  echo "  Waiting for ENIs to detach..."
  for i in $(seq 1 12); do
    eni_count=$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" --query "length(NetworkInterfaces)" --output text 2>/dev/null || echo "0")
    [ "$eni_count" = "0" ] && echo "  All ENIs detached." && break
    [ "$i" -eq 12 ] && echo "  WARNING: $eni_count ENIs still present after 60s."
    sleep 5
  done
  # Non-default security groups (safe to delete now that ENIs are gone)
  for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null && echo "  Deleted security group: $sg"
  done
fi
echo ""

# ── Step 3: CDK Destroy ────────────────────────────────────────────────────
echo "==> Step 3/4: CDK Destroy"
cd "$CDK_DIR"
cdk destroy --force || {
  echo "  CDK destroy failed. Force deleting stack..."
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" --deletion-mode FORCE_DELETE_STACK
  echo "  Waiting for force delete..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
}
cd "$REPO_ROOT"
echo ""

# ── Step 4: Post-destroy cleanup ───────────────────────────────────────────
echo "==> Step 4/4: Post-destroy cleanup"

# Log groups (CloudWatch Observability addon creates these outside CloudFormation)
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/openclaw" \
  --region "$REGION" --query "logGroups[*].logGroupName" --output text 2>/dev/null); do
  aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null && echo "  Deleted log group: $lg"
done

# CloudFront WAFs (CDK custom resource in us-east-1; onDelete not implemented)
for wacl_json in $(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query "WebACLs[?contains(Name,'$STACK')].{Id:Id,Name:Name,Lock:LockToken}" --output json 2>/dev/null \
  | python3 -c "import json,sys;[print(f'{w[\"Id\"]}|{w[\"Name\"]}|{w[\"Lock\"]}') for w in json.load(sys.stdin)]" 2>/dev/null); do
  IFS='|' read -r id name lock <<< "$wacl_json"
  aws wafv2 delete-web-acl --name "$name" --scope CLOUDFRONT --id "$id" --lock-token "$lock" --region us-east-1 2>/dev/null && echo "  Deleted WAF: $name"
done

# Final instance profile sweep (Karpenter may recreate during destroy)
for profile in $(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'openclaw') || contains(InstanceProfileName,'$STACK')].InstanceProfileName" \
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
