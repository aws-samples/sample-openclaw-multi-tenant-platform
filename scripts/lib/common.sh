#!/usr/bin/env bash
# Shared library for OpenClaw Platform scripts
# Usage: source scripts/lib/common.sh

set -euo pipefail

REGION="${REGION:-$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-west-2}")}"
STACK="${STACK:-OpenClawEksStack}"

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
