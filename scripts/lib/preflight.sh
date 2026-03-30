#!/usr/bin/env bash
# Pre-flight checks for OpenClaw Platform deployment
# Usage: source scripts/lib/preflight.sh && preflight_all
#    or: bash scripts/lib/preflight.sh (standalone)
set -euo pipefail

FAILURES=0

check_command() {
  local cmd="$1" label="$2" url="$3"
  if command -v "$cmd" &>/dev/null; then
    local ver
    case "$cmd" in
      aws)   ver=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2) ;;
      node)  ver=$(node --version) ;;
      kubectl) ver=$(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | tr -d ' ",' | cut -d: -f2) ;;
      helm)  ver=$(helm version --short 2>/dev/null | cut -d+ -f1) ;;
      docker) ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') ;;
      *)     ver="ok" ;;
    esac
    printf "  ✅ %s (%s)\n" "$label" "$ver"
    return 0
  else
    printf "  ❌ %s not found — install: %s\n" "$label" "$url"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

check_aws_identity() {
  if aws sts get-caller-identity &>/dev/null; then
    local acct region
    acct=$(aws sts get-caller-identity --query Account --output text)
    region=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-unset}")
    printf "  ✅ AWS identity (account %s, %s)\n" "$acct" "$region"
    return 0
  else
    printf "  ❌ AWS identity — run: aws configure\n"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

check_aws_region() {
  local region
  region=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-}")
  if [[ -n "$region" ]]; then
    printf "  ✅ AWS region (%s)\n" "$region"
    return 0
  else
    printf "  ❌ AWS region not set — run: aws configure set region us-west-2\n"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

check_cdk_json() {
  if [[ -f "cdk/cdk.json" ]]; then
    printf "  ✅ cdk/cdk.json exists\n"
    return 0
  else
    printf "  ❌ cdk/cdk.json not found — run: cp cdk/cdk.json.example cdk/cdk.json\n"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

check_no_placeholders() {
  if [[ ! -f "cdk/cdk.json" ]]; then
    return 0  # skip if no cdk.json (caught by check_cdk_json)
  fi
  local found
  found=$(grep -cE '<HOSTED_ZONE_ID>|your-domain\.com|YOUR_ALB_CLIENT_ID' cdk/cdk.json 2>/dev/null || true)
  if [[ "$found" -eq 0 ]]; then
    printf "  ✅ No placeholder values in cdk.json\n"
    return 0
  else
    printf "  ❌ cdk.json has %s placeholder(s) — edit cdk/cdk.json and fill in real values\n" "$found"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

check_docker_running() {
  if docker info &>/dev/null; then
    printf "  ✅ Docker (running)\n"
    return 0
  else
    printf "  ❌ Docker not running — start Docker Desktop or dockerd\n"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

preflight_all() {
  FAILURES=0
  echo "Pre-flight checks:"
  check_command "aws"     "AWS CLI v2"  "https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html" || true
  check_command "node"    "Node.js 22+" "https://nodejs.org/" || true
  check_command "kubectl" "kubectl"     "https://kubernetes.io/docs/tasks/tools/" || true
  check_command "helm"    "Helm 3"      "https://helm.sh/docs/intro/install/" || true
  check_command "docker"  "Docker"      "https://docs.docker.com/get-docker/" || true
  check_aws_identity || true
  check_aws_region || true
  check_cdk_json || true
  check_no_placeholders || true
  if command -v docker &>/dev/null; then
    check_docker_running || true
  fi
  echo ""
  if [[ "$FAILURES" -gt 0 ]]; then
    echo "$FAILURES check(s) failed. Fix and retry."
  else
    echo "All checks passed."
  fi
  return "$FAILURES"
}

# Run standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  preflight_all
fi
