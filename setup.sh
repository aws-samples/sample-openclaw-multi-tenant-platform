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

# ── Parse args ──────────────────────────────────────────────────────────────
usage() {
  echo "Usage: ./setup.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --phase N    Start from phase N (1-4)"
  echo "  --check      Run pre-flight checks only"
  echo "  --help       Show this help"
  exit 0
}

CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      if ! [[ "$2" =~ ^[1-4]$ ]]; then
        echo "Error: --phase must be 1-4"
        exit 1
      fi
      START_PHASE="$2"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
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
  (cd cdk && npm ci && npx cdk deploy OpenClawEksStack --require-approval broadening)
}
phase1_verify() {
  aws cloudformation describe-stacks --stack-name OpenClawEksStack --query 'Stacks[0].StackStatus' --output text 2>/dev/null | grep -qE 'CREATE_COMPLETE|UPDATE_COMPLETE'
}

phase2_run() {
  if [[ -f scripts/build-operator.sh ]]; then
    bash scripts/build-operator.sh
  else
    echo "  Building operator..."
    (cd operator && cargo build --release)
    echo "  Applying CRD + deployment..."
    kubectl apply -f operator/yaml/crd.yaml
    kubectl apply -f operator/yaml/deployment.yaml
  fi
}
phase2_verify() {
  kubectl get pods -n openclaw-system -l app=tenant-operator --no-headers 2>/dev/null | grep -q Running
}

phase3_run() {
  bash scripts/setup-keda.sh
  # Cognito triggers are now managed by CDK Custom Resource — no manual setup needed
}
phase3_verify() {
  kubectl get pods -n keda --no-headers 2>/dev/null | grep -q Running
}

phase4_run() {
  bash scripts/deploy-auth-ui.sh
}
phase4_verify() {
  local domain
  domain=$(node -e "console.log(require('./cdk/cdk.json').context.zoneName)" 2>/dev/null || echo "")
  if [[ -z "$domain" ]]; then
    echo "  (skipping URL check — domain not configured)"
    return 0
  fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null || echo "000")
  [[ "$code" == "200" || "$code" == "403" ]]
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
echo "  2/4: Operator (build + deploy)  ~3 min"
echo "  3/4: Platform (KEDA + Cognito)  ~2 min"
echo "  4/4: Auth UI                    ~1 min"
echo ""
printf "Start? (Y/n) "
read -r answer
if [[ "$answer" == "n" || "$answer" == "N" ]]; then
  echo "Aborted."
  exit 0
fi

run_phase 1 "Infrastructure (CDK)"      phase1_run phase1_verify
run_phase 2 "Operator (build + deploy)" phase2_run phase2_verify
run_phase 3 "Platform (KEDA + Cognito)" phase3_run phase3_verify
run_phase 4 "Auth UI"                   phase4_run phase4_verify

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo ""
echo "════════════════════════════════════"
echo "  ✅ OpenClaw Platform deployed!"
echo "  Total time: ${MINS}m ${SECS}s"
echo "════════════════════════════════════"
