#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run() {
  echo "  → $*"
  $DRY_RUN || "$@"
}

echo "==> Installing KEDA + HTTP Add-on"

echo "  Step 1: Add Helm repo"
run helm repo add kedacore https://kedacore.github.io/charts
run helm repo update kedacore

echo "  Step 2: Install KEDA"
run helm install keda kedacore/keda --namespace keda --create-namespace --wait --timeout 120s

echo "  Step 3: Install HTTP Add-on"
run helm install http-add-on kedacore/keda-add-ons-http --namespace keda --wait --timeout 120s

echo "  Step 4: Verify"
if ! $DRY_RUN; then
  kubectl get pods -n keda
fi

echo ""
echo "=== KEDA Installed ==="
echo "  To enable scale-to-zero for a tenant:"
echo "    helm upgrade openclaw-<name> helm/charts/openclaw-platform \\"
echo "      -n openclaw-<name> --set scaleToZero.enabled=true"
echo "======================"
