#!/usr/bin/env bash
# Run all post-deploy setup scripts in correct order
# Usage: bash scripts/setup-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd kubectl
require_cmd helm
require_cmd aws

STEPS=(
  "setup-keda.sh"
  "setup-cognito.sh"
  "post-deploy.sh"
  "setup-waf.sh"
)

TOTAL=${#STEPS[@]}
for i in "${!STEPS[@]}"; do
  step="${STEPS[$i]}"
  n=$((i + 1))
  script="${SCRIPT_DIR}/${step}"
  log_info "[$n/$TOTAL] Running ${step}"
  if [[ ! -f "$script" ]]; then
    log_error "${step} not found, aborting"
    exit 1
  fi
  if ! bash "$script"; then
    log_error "${step} failed, aborting"
    exit 1
  fi
  log_info "[$n/$TOTAL] ${step} completed"
done

log_info "All $TOTAL steps completed successfully"
