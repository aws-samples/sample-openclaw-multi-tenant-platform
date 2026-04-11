#!/usr/bin/env bash
# Enhanced force cleanup with nested stacks handling and comprehensive verification
# Addresses coverage gaps found in original force-cleanup.sh
#
# Usage: ./scripts/enhanced-force-cleanup.sh [--region REGION] [--dry-run]
#
# Improvements:
# 1. Handles nested stacks explicitly
# 2. Comprehensive resource verification
# 3. Better error handling and reporting
# 4. Dry-run mode for testing
# 5. Progress tracking and logging

set -euo pipefail

REGION="${AWS_REGION:-${1:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"
DRY_RUN=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help)
      echo "Usage: $0 [--region REGION] [--dry-run] [--verbose]"
      echo "  --dry-run: Show what would be deleted without actually deleting"
      echo "  --verbose: Show detailed progress"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

STACK="OpenClawEksStack"
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# Logging functions
log() {
  echo "[$(date '+%H:%M:%S')] $*"
  [[ "$VERBOSE" == "true" ]] && echo "[$(date '+%H:%M:%S')] $*" >&2
}

log_error() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }
log_warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }

# Dry-run wrapper
run_cmd() {
  local cmd="$*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would run: $cmd"
    return 0
  else
    log "Running: $cmd"
    eval "$cmd"
  fi
}

# Resource discovery functions
discover_nested_stacks() {
  local parent_stack="$1"
  aws cloudformation list-stack-resources --stack-name "$parent_stack" --region "$REGION" \
    --query 'StackResourceSummaries[?ResourceType==`AWS::CloudFormation::Stack`].PhysicalResourceId' \
    --output text 2>/dev/null || echo ""
}

discover_all_openclaw_stacks() {
  aws cloudformation list-stacks --region "$REGION" \
    --query 'StackSummaries[?contains(StackName,`OpenClaw`) && StackStatus!=`DELETE_COMPLETE`].StackName' \
    --output text 2>/dev/null || echo ""
}

discover_openclaw_resources() {
  echo "==> Discovering OpenClaw resources in $REGION..."

  # CloudFormation stacks
  local all_stacks
  all_stacks=$(discover_all_openclaw_stacks)
  [[ -n "$all_stacks" ]] && echo "Stacks: $all_stacks" || echo "Stacks: none"

  # EKS clusters
  local eks_clusters
  eks_clusters=$(aws eks list-clusters --region "$REGION" --query 'clusters[?contains(@,`openclaw`)]' --output text 2>/dev/null || echo "")
  [[ -n "$eks_clusters" ]] && echo "EKS clusters: $eks_clusters" || echo "EKS clusters: none"

  # ALBs
  local albs
  albs=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerName" --output text 2>/dev/null || echo "")
  [[ -n "$albs" ]] && echo "ALBs: $albs" || echo "ALBs: none"

  # VPCs
  local vpcs
  vpcs=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:aws:cloudformation:stack-name,Values=*OpenClaw*" \
    --query 'Vpcs[*].VpcId' --output text 2>/dev/null || echo "")
  [[ -n "$vpcs" ]] && echo "VPCs: $vpcs" || echo "VPCs: none"

  echo ""
}

# Enhanced stack deletion with nested stack support
delete_stack_recursive() {
  local stack_name="$1"
  local max_attempts="${2:-30}"

  log "Processing stack: $stack_name"

  # Check if stack exists
  local stack_status
  stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "does not exist")

  if [[ "$stack_status" == *"does not exist"* ]]; then
    log "Stack $stack_name does not exist, skipping"
    return 0
  fi

  # If stack is already being deleted, wait for completion
  if [[ "$stack_status" == "DELETE_IN_PROGRESS" ]]; then
    log "Stack $stack_name already deleting, waiting for completion..."
    wait_for_stack_deletion "$stack_name"
    return $?
  fi

  # Discover and delete nested stacks first
  log "Discovering nested stacks for $stack_name..."
  local nested_stacks
  nested_stacks=$(discover_nested_stacks "$stack_name")

  if [[ -n "$nested_stacks" ]]; then
    log "Found nested stacks: $nested_stacks"
    for nested_stack in $nested_stacks; do
      # Extract just the stack name from full ARN
      local nested_name
      nested_name=$(basename "$nested_stack")
      log "Recursively deleting nested stack: $nested_name"
      delete_stack_recursive "$nested_name" 10
    done
  fi

  # Now delete the main stack
  log "Deleting main stack: $stack_name"
  run_cmd "aws cloudformation delete-stack --stack-name $stack_name --region $REGION"

  # Wait for deletion completion
  wait_for_stack_deletion "$stack_name" "$max_attempts"
}

wait_for_stack_deletion() {
  local stack_name="$1"
  local max_attempts="${2:-30}"

  log "Waiting for stack deletion: $stack_name (max ${max_attempts} attempts)"

  for attempt in $(seq 1 "$max_attempts"); do
    local status
    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "does not exist")

    if [[ "$status" == *"does not exist"* ]]; then
      log "✅ Stack $stack_name deleted successfully"
      return 0
    elif [[ "$status" == "DELETE_FAILED" ]]; then
      log_error "Stack $stack_name deletion failed"

      # Get failed resources
      local failed_resources
      failed_resources=$(aws cloudformation list-stack-resources --stack-name "$stack_name" --region "$REGION" \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null || echo "")

      if [[ -n "$failed_resources" ]]; then
        log "Failed resources: $failed_resources"
        log "Retrying with retain..."
        run_cmd "aws cloudformation delete-stack --stack-name $stack_name --region $REGION --retain-resources $failed_resources"
      else
        log_error "No failed resources found, cannot retry"
        return 1
      fi
    elif [[ "$status" == "DELETE_IN_PROGRESS" ]]; then
      log "Still deleting... (attempt $attempt/$max_attempts)"
      sleep 30
    else
      log_warn "Unexpected status: $status (attempt $attempt/$max_attempts)"
      sleep 30
    fi
  done

  log_error "Timeout waiting for stack deletion: $stack_name"
  return 1
}

# Enhanced cleanup with verification
cleanup_openclaw_resources() {
  echo "==> Enhanced OpenClaw Cleanup ($REGION)"
  [[ "$DRY_RUN" == "true" ]] && echo "==> DRY RUN MODE - No resources will be actually deleted"
  echo ""

  # Step 1: Discover all resources
  discover_openclaw_resources

  # Step 2: Delete tenants (if accessible)
  echo "Step 1: Deleting tenants..."
  if kubectl get applicationset openclaw-tenants -n argocd &>/dev/null; then
    local tenants
    tenants=$(kubectl get applicationset openclaw-tenants -n argocd \
      -o jsonpath='{.spec.generators[0].list.elements[*].name}' 2>/dev/null || echo "")
    if [[ -n "$tenants" ]]; then
      for tenant in $tenants; do
        log "Deleting tenant: $tenant"
        run_cmd "bash $(dirname $0)/delete-tenant.sh $tenant --force"
      done
    else
      log "No tenants found"
    fi
  else
    log "ApplicationSet not accessible (cluster may be deleted)"
  fi

  # Step 3: Delete ALBs and target groups
  echo "Step 2: Deleting ALBs and target groups..."
  local alb_arns
  alb_arns=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text 2>/dev/null || echo "")

  if [[ -n "$alb_arns" ]]; then
    for alb_arn in $alb_arns; do
      [[ "$alb_arn" == "None" || -z "$alb_arn" ]] && continue
      log "Deleting ALB: $alb_arn"
      run_cmd "aws elbv2 delete-load-balancer --load-balancer-arn $alb_arn --region $REGION"
    done

    # Wait for ENI cleanup
    [[ "$DRY_RUN" != "true" ]] && sleep 15
  fi

  # Clean target groups
  local tg_arns
  tg_arns=$(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?contains(TargetGroupName,'openclaw')].TargetGroupArn" --output text 2>/dev/null || echo "")

  if [[ -n "$tg_arns" ]]; then
    for tg_arn in $tg_arns; do
      [[ "$tg_arn" == "None" || -z "$tg_arn" ]] && continue
      log "Deleting target group: $tg_arn"
      run_cmd "aws elbv2 delete-target-group --target-group-arn $tg_arn --region $REGION"
    done
  fi

  # Step 4: Delete all OpenClaw stacks (including nested)
  echo "Step 3: Deleting CloudFormation stacks (including nested)..."
  local all_stacks
  all_stacks=$(discover_all_openclaw_stacks)

  if [[ -n "$all_stacks" ]]; then
    # Sort stacks to delete nested first, then parents
    echo "$all_stacks" | tr ' ' '\n' | sort -r | while read -r stack; do
      [[ -z "$stack" || "$stack" == "None" ]] && continue
      delete_stack_recursive "$stack"
    done
  else
    log "No OpenClaw stacks found"
  fi

  # Step 5: Clean CloudFront WAF (global resources)
  if [[ "$REGION" == "us-east-1" ]] || [[ "$DRY_RUN" == "true" ]]; then
    echo "Step 4: Cleaning CloudFront WAF (us-east-1)..."
    local waf_acls
    waf_acls=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
      --query "WebACLs[?contains(Name,'OpenClaw')].Name" --output text 2>/dev/null || echo "")

    if [[ -n "$waf_acls" ]]; then
      for waf_name in $waf_acls; do
        [[ "$waf_name" == "None" || -z "$waf_name" ]] && continue
        log "Would delete WAF ACL: $waf_name"
        # Note: WAF deletion requires getting LockToken first
        if [[ "$DRY_RUN" != "true" ]]; then
          # Implementation would go here - complex due to LockToken requirement
          log_warn "WAF cleanup requires manual intervention (LockToken complexity)"
        fi
      done
    fi
  fi

  # Step 6: Verification
  echo "Step 5: Verification..."
  sleep 10  # Allow for eventual consistency

  local remaining_stacks
  remaining_stacks=$(discover_all_openclaw_stacks)
  if [[ -n "$remaining_stacks" ]]; then
    log_warn "Remaining stacks found: $remaining_stacks"
    echo "Some resources may still be cleaning up. Run again in a few minutes."
  else
    log "✅ All OpenClaw stacks cleaned up"
  fi

  # Final resource check
  echo ""
  echo "==> Final resource check..."
  discover_openclaw_resources

  echo ""
  echo "=== Enhanced Cleanup Summary ==="
  echo "Region: $REGION"
  echo "Mode: $([[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN" || echo "ACTUAL")"
  echo "Time: $(date)"
  echo "==============================="
}

# Main execution
main() {
  log "Starting enhanced OpenClaw cleanup..."
  log "Region: $REGION"
  log "Dry run: $DRY_RUN"
  log "Verbose: $VERBOSE"
  echo ""

  cleanup_openclaw_resources

  echo ""
  log "Enhanced cleanup completed!"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "This was a dry run. To actually delete resources, run:"
    echo "$0 --region $REGION"
  fi
}

# Execute main function
main