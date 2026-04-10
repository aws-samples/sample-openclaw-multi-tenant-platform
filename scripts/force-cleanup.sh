#!/usr/bin/env bash
# Force cleanup: accelerate CloudFormation rollback/destroy by removing known blockers.
# Usage: ./scripts/force-cleanup.sh [--delete]
#   Without --delete: accelerate rollback only
#   With --delete: accelerate rollback, then delete the stack
set -euo pipefail

STACK="OpenClawEksStack"
REGION="${AWS_REGION:-us-east-1}"
DELETE_STACK=false
[[ "${1:-}" == "--delete" ]] && DELETE_STACK=true

echo "==> Force cleanup for $STACK in $REGION"

# 0. Delete Kubernetes-managed ALB (created by ALB Controller, not CDK)
echo "  -> Removing Kubernetes-managed ALBs..."
for alb_arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null); do
  [[ -n "$alb_arn" && "$alb_arn" != "None" ]] && \
    aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$REGION" 2>/dev/null && \
    echo "     Deleted ALB: $alb_arn"
done
sleep 10  # Wait for ALB ENIs to release

# 1. Kill ASG lifecycle hooks (EKS adds 30-min terminate hooks)
echo "  -> Removing ASG lifecycle hooks..."
for asg in $(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'eks')].AutoScalingGroupName" --output text 2>/dev/null); do
  for hook in $(aws autoscaling describe-lifecycle-hooks --auto-scaling-group-name "$asg" --region "$REGION" \
    --query "LifecycleHooks[?contains(LifecycleHookName,'Terminate')].LifecycleHookName" --output text 2>/dev/null); do
    aws autoscaling delete-lifecycle-hook --lifecycle-hook-name "$hook" \
      --auto-scaling-group-name "$asg" --region "$REGION" 2>/dev/null && echo "     Deleted hook: $hook on $asg"
  done
  # Force scale to 0 to speed up instance termination
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg" \
    --min-size 0 --desired-capacity 0 --region "$REGION" 2>/dev/null && echo "     Scaled to 0: $asg"
done

# 2. Find VPC
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  # 3. Delete GuardDuty managed security groups and ALB security groups
  echo "  -> Cleaning security groups..."
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output text 2>/dev/null | while read sg name; do
    if [[ "$name" == *"GuardDuty"* || "$name" == *"k8s-"* ]]; then
      aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null && echo "     Deleted SG: $sg ($name)"
    fi
  done

  # 4. Delete VPC endpoints
  echo "  -> Cleaning VPC endpoints..."
  aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null | tr '\t' '\n' | while read vpce; do
    [[ -n "$vpce" && "$vpce" != "None" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vpce" --region "$REGION" 2>/dev/null && echo "     Deleted VPCE: $vpce"
  done
fi

# 5. Wait for rollback/delete to complete
echo "  -> Waiting for stack to stabilize..."
while true; do
  STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>&1)
  if [[ "$STATUS" == *"does not exist"* ]]; then
    echo "  Stack deleted."
    break
  fi
  if [[ "$STATUS" != *"IN_PROGRESS"* ]]; then
    echo "  Stack status: $STATUS"
    break
  fi
  # Keep cleaning blockers while waiting
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v None | xargs -I{} aws ec2 delete-security-group --group-id {} --region "$REGION" 2>/dev/null
    aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null | grep -v None | tr '\t' '\n' | while read vpce; do [[ -n "$vpce" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vpce" --region "$REGION" 2>/dev/null; done
  fi
  sleep 15
done

# 6. Delete stack if requested
if $DELETE_STACK && [[ "$STATUS" == "ROLLBACK_COMPLETE" ]]; then
  echo "  -> Deleting stack..."
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null
  echo "  Stack deleted."
fi

echo ""
echo "=== Force cleanup complete ==="
