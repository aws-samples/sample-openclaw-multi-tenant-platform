#!/usr/bin/env bash
# OpenClaw Platform Setup — one-command guided deployment
# Usage: ./setup.sh              # Run all phases
#        ./setup.sh --phase 2    # Start from Phase 2
#        ./setup.sh --check      # Pre-flight only
#        ./setup.sh --help       # Usage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_PHASE=0
START_TIME=$(date +%s)

# Generate and export stack name for consistency across deployment session
if [[ -z "${CDK_STACK_SUFFIX:-}" ]]; then
  export CDK_STACK_SUFFIX=$(date +%Y-%m-%dT%H-%M-%S)
fi
export CDK_STACK_NAME="OpenClawEksStack-${CDK_STACK_SUFFIX}"

# ── Parse args ──────────────────────────────────────────────────────────────
usage() {
  echo "Usage: ./setup.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --phase N    Start from phase N (1-4)"
  echo "  --check      Run pre-flight checks only"
  echo "  --yes        Skip confirmation prompt"
  echo "  --help       Show this help"
  exit 0
}

CHECK_ONLY=false
AUTO_CONFIRM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      if ! [[ "$2" =~ ^[1-4]$ ]]; then
        echo "Error: --phase must be 1-4"
        exit 1
      fi
      START_PHASE="$2"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    --yes)   AUTO_CONFIRM=true; shift ;;
    --help)  usage ;;
    *)       echo "Unknown option: $1"; usage ;;
  esac
done

# ── Source lib modules ──────────────────────────────────────────────────────
source "$SCRIPT_DIR/scripts/lib/preflight.sh"
source "$SCRIPT_DIR/scripts/lib/generate-config.sh"

# ── Phase runner ────────────────────────────────────────────────────────────
run_phase() {
  local phase_num="$1" phase_name="$2" phase_fn="$3" verify_fn="$4"
  if [[ "$START_PHASE" -gt "$phase_num" ]]; then
    echo "Phase ${phase_num}/4: ${phase_name} — skipped"
    return 0
  fi
  echo ""
  echo "Phase ${phase_num}/4: ${phase_name}"
  echo "────────────────────────────────────"
  if $phase_fn; then
    if $verify_fn; then
      echo "  ✅ ${phase_name} complete"
    else
      echo "  ❌ ${phase_name} deployed but verification failed"
      echo "  Retry: ./setup.sh --phase ${phase_num}"
      exit 1
    fi
  else
    echo "  ❌ ${phase_name} failed"
    echo "  Retry: ./setup.sh --phase ${phase_num}"
    exit 1
  fi
}

# ── Phase functions ─────────────────────────────────────────────────────────
phase1_run() {
  echo "  📋 Deploying stack: $CDK_STACK_NAME"
  local approval_flag="--require-approval broadening"
  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    approval_flag="--require-approval never"
    echo "  🚀 Auto-confirming CDK deployment for non-interactive mode"
  fi
  (cd cdk && npm ci && npx cdk deploy $approval_flag)
}
phase1_verify() {
  source "$SCRIPT_DIR/scripts/lib/common.sh"
  aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null | grep -qE 'CREATE_COMPLETE|UPDATE_COMPLETE'
}

phase2_run() {
  echo "  Installing ArgoCD via Helm..."
  echo "  Configuring kubectl..."
  local _region _cluster
  _region="$(aws configure get region 2>/dev/null || echo us-west-2)"
  _cluster=$(aws cloudformation describe-stacks --region "$_region" \
    --query "Stacks[?starts_with(StackName,'OpenClawEksStack') && StackStatus!='DELETE_COMPLETE']|[0].Outputs[?OutputKey=='ClusterName'].OutputValue|[0]" \
    --output text 2>/dev/null)
  [ -z "$_cluster" ] || [ "$_cluster" = "None" ] && _cluster="$(node -e "console.log(require('cdk/cdk.json').context.clusterName || '')" 2>/dev/null)"
  [ -z "$_cluster" ] && { echo "ERROR: Could not determine cluster name from stack outputs or cdk.json"; return 1; }
  aws eks update-kubeconfig --region "$_region" --name "$_cluster"
  bash scripts/setup-argocd.sh
}
phase2_verify() {
  kubectl get crd applicationsets.argoproj.io &>/dev/null
}

phase3_run() {
  echo "  Deploying ApplicationSet + Gateway..."
  bash scripts/deploy-platform.sh
}
phase3_verify() {
  kubectl get applicationset openclaw-tenants -n argocd --no-headers 2>/dev/null | grep -q openclaw-tenants
}

phase4_run() {
  bash scripts/setup-keda.sh
}
phase4_verify() {
  kubectl get pods -n keda --no-headers 2>/dev/null | grep -q Running
}

# ── Main ────────────────────────────────────────────────────────────────────
echo ""
echo "OpenClaw Platform Setup"
echo "========================"
echo ""

# Pre-flight
if ! preflight_all; then
  if [[ ! -f "cdk/cdk.json" ]]; then
    printf "\nGenerate cdk.json now? (Y/n) "
    read -r answer
    if [[ "$answer" != "n" && "$answer" != "N" ]]; then
      generate_config
      echo ""
      echo "Re-running pre-flight..."
      if ! preflight_all; then
        echo "Fix remaining issues and retry."
        exit 1
      fi
    else
      exit 1
    fi
  else
    exit 1
  fi
fi

if $CHECK_ONLY; then
  exit 0
fi

echo ""
echo "Phases:"
echo "  1/4: Infrastructure (CDK)       ~15 min"
echo "  2/4: ArgoCD (Helm)    ~3 min"
echo "  3/4: Platform (ApplicationSet)  ~1 min"
echo "  4/4: KEDA (scale-to-zero)       ~2 min"
echo ""
if [[ "$AUTO_CONFIRM" == "true" ]]; then
  echo "Auto-starting deployment..."
else
  printf "Start? (Y/n) "
  read -r answer
  if [[ "$answer" == "n" || "$answer" == "N" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

run_phase 1 "Infrastructure (CDK)"      phase1_run phase1_verify
run_phase 2 "ArgoCD (Helm)" phase2_run phase2_verify
run_phase 3 "Platform (ApplicationSet + Gateway)" phase3_run phase3_verify
run_phase 4 "KEDA (scale-to-zero)" phase4_run phase4_verify

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo ""
echo "════════════════════════════════════"
echo "  ✅ OpenClaw Platform deployed!"
echo "  Total time: ${MINS}m ${SECS}s"
echo "════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Create your first tenant:"
echo "     ./scripts/create-tenant.sh <name> --email <email>"
echo "  2. After the first tenant pod is running, finalize networking:"
echo "     ./scripts/post-deploy.sh    # Add ALB origin to CloudFront + Route53 + WAF"
echo ""
echo "  post-deploy.sh requires the ALB to exist (created by LB Controller"
echo "  when the first HTTPRoute is reconciled). Run it after step 1."
