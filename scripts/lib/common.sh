#!/usr/bin/env bash
# Shared library for OpenClaw Platform scripts
# Usage: source scripts/lib/common.sh

set -euo pipefail

REGION="${REGION:-${AWS_DEFAULT_REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}}}"

# Dynamic stack name discovery
discover_stack_name() {
  # 1. Use explicit override
  if [[ -n "${CDK_STACK_NAME:-}" ]]; then
    echo "$CDK_STACK_NAME"
    return
  fi

  # 2. Discover from active deployments (excluding nested stacks)
  local active_stack
  active_stack=$(aws cloudformation list-stacks --region "$REGION" \
    --query 'StackSummaries[?starts_with(StackName,`OpenClawEksStack`) && StackStatus!=`DELETE_COMPLETE` && !contains(StackName,`NestedStack`)].StackName' \
    --output text 2>/dev/null | head -1 || echo "")

  if [[ -n "$active_stack" && "$active_stack" != "None" ]]; then
    echo "$active_stack"
    return
  fi

  # 3. Fallback to legacy name for backward compatibility
  echo "OpenClawEksStack"
}

STACK="${STACK:-$(discover_stack_name)}"

# Cluster name — read from stack outputs (dynamic), fallback to cdk.json context
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
if [[ -z "${CLUSTER:-}" ]]; then
  CLUSTER=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text 2>/dev/null || echo "")
fi
if [[ -z "${CLUSTER:-}" ]] && [[ -f "${_REPO_ROOT}/cdk/cdk.json" ]]; then
  CLUSTER="$(node -e "console.log(require('${_REPO_ROOT}/cdk/cdk.json').context.clusterName || '')" 2>/dev/null || echo '')"
fi
CLUSTER="${CLUSTER:-openclaw-cluster}"

# Extract CloudFormation stack output by key
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null
}

# Check if a command exists, exit if not
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    log_error "$1 is required but not found"
    return 1
  fi
}

# Colored log helpers
log_info() {
  printf "\033[0;32m[INFO]\033[0m %s\n" "$*"
}

log_error() {
  printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2
}

# Check if a Kubernetes resource exists before creating
# Usage: ensure_idempotent <resource_type> <name> [namespace]
ensure_idempotent() {
  local kind="$1" rname="$2"
  local ns_flag=""
  if [[ -n "${3:-}" ]]; then
    ns_flag="-n $3"
  fi
  # shellcheck disable=SC2086
  if kubectl get "$kind" "$rname" $ns_flag &>/dev/null; then
    log_info "$kind/$rname already exists, skipping"
    return 1
  fi
  return 0
}

# Verify kubectl can reach the cluster
require_cluster() {
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster."
    log_error "Run: aws eks update-kubeconfig --region <region> --name ${CLUSTER}"
    exit 1
  fi
}
