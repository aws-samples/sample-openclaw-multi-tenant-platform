#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

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
run helm upgrade --install keda kedacore/keda --namespace keda --create-namespace --wait --timeout 120s

echo "  Step 3: Install HTTP Add-on"
# Use longer timeout (180s) — first install pulls images which can be slow.
# Don't let failure block TGC creation below (TGC is critical for scale-from-zero).
if ! run helm upgrade --install http-add-on kedacore/keda-add-ons-http --namespace keda --wait --timeout 180s \
  --set interceptor.replicas.min=1 \
  --set interceptor.replicas.max=1 \
  --set interceptor.config.waitTimeout=90s \
  --set scaler.replicas=1; then
  echo "  ⚠️  HTTP Add-on helm install timed out (pods may still be starting)."
  echo "  Continuing with TGC creation — pods will become ready shortly."
fi

echo "  Step 4: Verify"
if ! $DRY_RUN; then
  kubectl get pods -n keda
fi

echo ""
echo "==> Creating shared interceptor TargetGroupConfiguration"
kubectl wait --for=condition=Established crd/targetgroupconfigurations.gateway.k8s.aws --timeout=30s 2>/dev/null || true
kubectl apply -f - <<'EOF'
apiVersion: gateway.k8s.aws/v1beta1
kind: TargetGroupConfiguration
metadata:
  name: keda-interceptor-tg
  namespace: keda
  labels:
    app.kubernetes.io/managed-by: setup-keda
spec:
  targetReference:
    name: keda-add-ons-http-interceptor-proxy
  defaultConfiguration:
    targetType: ip
    healthCheckConfig:
      healthCheckPath: /readyz
      healthCheckPort: "9090"
      healthyThresholdCount: 2
      unhealthyThresholdCount: 2
      healthCheckInterval: 15
EOF

echo ""
echo "=== KEDA Installed ==="
echo "  Interceptor TGC created in keda namespace."
echo "  Scale-to-zero is managed by ApplicationSet per-tenant values."
echo "======================"
