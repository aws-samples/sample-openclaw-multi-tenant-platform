#!/usr/bin/env bash
# Full cleanup: delete all OpenClaw resources in the correct order.
# Handles all known blockers (lifecycle hooks, GuardDuty SGs, K8s ALBs, VPC endpoints, orphan instances).
#
# Usage: ./scripts/force-cleanup.sh [--region REGION]
#
# Deletion order (cross-region dependency):
#   1. Delete tenants (Pod Identity, Secrets Manager, ArgoCD Applications)
#   2. Delete K8s-managed ALB (not managed by CDK)
#   3. CDK destroy OpenClawEksStack (EKS, VPC, Lambda, CloudFront, etc.)
#      - Accelerate: kill ASG lifecycle hooks, scale to 0, clean GuardDuty SGs, VPC endpoints
#   4. CDK destroy OpenClawWafStack (must wait for EKS stack — cross-region export dependency)
#   5. Clean retained resources (EFS, S3 buckets, orphan IAM roles)
set -euo pipefail

REGION="${AWS_REGION:-${1:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
# Accept --region flag
[[ "${1:-}" == "--region" ]] && REGION="${2:-$REGION}"
STACK="OpenClawEksStack"
WAF_STACK="OpenClawWafStack"
CLUSTER_NAME="openclaw-cluster"

log() { echo "  $(date '+%H:%M:%S') $*"; }

echo "==> OpenClaw Full Cleanup (${REGION})"
echo ""

# ── Step 1: Delete tenants ──────────────────────────────────────────────────
echo "Step 1: Deleting tenants..."
if kubectl get applicationset openclaw-tenants -n argocd &>/dev/null; then
  for tenant in $(kubectl get applicationset openclaw-tenants -n argocd \
    -o jsonpath='{.spec.generators[0].list.elements[*].name}' 2>/dev/null); do
    log "Deleting tenant: $tenant"
    bash "$(dirname "$0")/delete-tenant.sh" "$tenant" --force 2>/dev/null || true
  done
else
  log "No ApplicationSet found (cluster may already be deleted)"
fi

# ── Step 2: Delete K8s-managed ALB ──────────────────────────────────────────
echo "Step 2: Deleting K8s-managed ALBs..."
for alb_arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null); do
  [[ -z "$alb_arn" || "$alb_arn" == "None" ]] && continue
  log "Deleting ALB: $alb_arn"
  aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$REGION" 2>/dev/null
done
sleep 15  # Wait for ALB ENIs to release

# ── Step 3: CDK destroy EKS stack ──────────────────────────────────────────
echo "Step 3: Destroying EKS stack..."

# Check current state
EKS_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "does not exist")

if [[ "$EKS_STATUS" == *"does not exist"* ]]; then
  log "EKS stack already deleted"
else
  # If not already deleting, initiate destroy
  if [[ "$EKS_STATUS" != *"DELETE_IN_PROGRESS"* ]]; then
    if [[ "$EKS_STATUS" == "DELETE_FAILED" ]]; then
      FAILED=$(aws cloudformation list-stack-resources --stack-name "$STACK" --region "$REGION" \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null)
      log "Previous delete failed. Retaining: $FAILED"
      aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" --retain-resources $FAILED 2>/dev/null
    else
      log "Initiating stack deletion..."
      aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null
    fi
  fi

  # Accelerate deletion loop
  log "Accelerating deletion (clearing blockers)..."
  for attempt in $(seq 1 60); do
    EKS_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "does not exist")
    [[ "$EKS_STATUS" == *"does not exist"* ]] && log "EKS stack deleted!" && break

    if [[ "$EKS_STATUS" == "DELETE_FAILED" ]]; then
      FAILED=$(aws cloudformation list-stack-resources --stack-name "$STACK" --region "$REGION" \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null)
      log "Delete failed. Retaining: $FAILED"
      aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" --retain-resources $FAILED 2>/dev/null
      continue
    fi

    # Kill ASG lifecycle hooks + scale to 0
    for asg in $(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --query "AutoScalingGroups[?contains(AutoScalingGroupName,'eks')].AutoScalingGroupName" --output text 2>/dev/null); do
      aws autoscaling delete-lifecycle-hook --lifecycle-hook-name Terminate-LC-Hook \
        --auto-scaling-group-name "$asg" --region "$REGION" 2>/dev/null
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg" \
        --min-size 0 --desired-capacity 0 --region "$REGION" 2>/dev/null
    done

    # Terminate orphan Karpenter instances
    for inst in $(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null); do
      [[ -n "$inst" ]] && aws ec2 terminate-instances --instance-ids "$inst" --region "$REGION" 2>/dev/null && log "Terminated: $inst"
    done

    # Clean VPC blockers
    VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
      --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
    if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
      # Security groups (GuardDuty + ALB)
      aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | tr '\t' '\n' | while read sg; do
        [[ -n "$sg" ]] && aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null
      done
      # VPC endpoints
      aws ec2 describe-vpc-endpoints --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null | tr '\t' '\n' | while read vpce; do
        [[ -n "$vpce" && "$vpce" != "None" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vpce" --region "$REGION" 2>/dev/null
      done
      # Orphan ENIs
      aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null | tr '\t' '\n' | while read eni; do
        [[ -n "$eni" ]] && aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null
      done
    fi

    sleep 15
  done
fi

# ── Step 4: Delete WAF stack ────────────────────────────────────────────────
echo "Step 4: Deleting WAF stack (us-east-1)..."
WAF_STATUS=$(aws cloudformation describe-stacks --stack-name "$WAF_STACK" --region us-east-1 \
  --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "does not exist")

if [[ "$WAF_STATUS" == *"does not exist"* ]]; then
  log "WAF stack already deleted"
else
  aws cloudformation delete-stack --stack-name "$WAF_STACK" --region us-east-1 2>/dev/null
  for i in $(seq 1 12); do
    WAF_STATUS=$(aws cloudformation describe-stacks --stack-name "$WAF_STACK" --region us-east-1 \
      --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "does not exist")
    [[ "$WAF_STATUS" == *"does not exist"* ]] && log "WAF stack deleted!" && break
    if [[ "$WAF_STATUS" == "DELETE_FAILED" ]]; then
      FAILED=$(aws cloudformation list-stack-resources --stack-name "$WAF_STACK" --region us-east-1 \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null)
      log "WAF delete failed. Retaining: $FAILED"
      aws cloudformation delete-stack --stack-name "$WAF_STACK" --region us-east-1 --retain-resources $FAILED 2>/dev/null
      # Manual WAF cleanup
      aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
        --query "WebACLs[?contains(Name,'CloudFrontWaf')]" --output json 2>/dev/null | python3 -c "
import json,sys,subprocess
for w in json.load(sys.stdin):
  subprocess.run(['aws','wafv2','delete-web-acl','--scope','CLOUDFRONT','--region','us-east-1',
    '--name',w['Name'],'--id',w['Id'],'--lock-token',w['LockToken']],capture_output=True)
" 2>/dev/null
    fi
    log "WAF: $WAF_STATUS"
    sleep 15
  done
fi

# ── Step 5: Clean retained resources ────────────────────────────────────────
echo "Step 5: Cleaning retained resources..."

# Orphan IAM roles (Karpenter instance profile)
for role in $(aws iam list-roles --query "Roles[?contains(RoleName,'OpenClawEksStack')].RoleName" --output text 2>/dev/null); do
  log "Cleaning IAM role: $role"
  aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[*].InstanceProfileName' --output text 2>/dev/null | tr '\t' '\n' | while read ip; do
    [[ -n "$ip" ]] && aws iam remove-role-from-instance-profile --role-name "$role" --instance-profile-name "$ip" 2>/dev/null && aws iam delete-instance-profile --instance-profile-name "$ip" 2>/dev/null
  done
  aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | while read arn; do
    [[ -n "$arn" ]] && aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" 2>/dev/null
  done
  aws iam list-role-policies --role-name "$role" --query 'PolicyNames[*]' --output text 2>/dev/null | tr '\t' '\n' | while read name; do
    [[ -n "$name" ]] && aws iam delete-role-policy --role-name "$role" --policy-name "$name" 2>/dev/null
  done
  aws iam delete-role --role-name "$role" 2>/dev/null
done

# Retained subnets + VPCs
for vpc in $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
  --query 'Vpcs[*].VpcId' --output text 2>/dev/null); do
  [[ -z "$vpc" || "$vpc" == "None" ]] && continue
  log "Cleaning retained VPC: $vpc"
  for sub in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$sub" --region "$REGION" 2>/dev/null
  done
  igw=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
  [[ -n "$igw" && "$igw" != "None" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null && aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null
  aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null && log "Deleted VPC: $vpc"
done

echo ""
echo "=== Cleanup Complete ==="
echo "  Retained data resources (manual cleanup if no longer needed):"
echo "    EFS:  aws efs describe-file-systems --query 'FileSystems[?contains(Name,\`TenantEfs\`)].FileSystemId' --region $REGION"
echo "    S3:   aws s3api list-buckets --query 'Buckets[?contains(Name,\`openclaweks\`)].Name'"
echo "========================"
