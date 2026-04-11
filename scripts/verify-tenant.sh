#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

TENANT="${1:?Usage: $0 <tenant-name> [--region <region>]}"
REGION="${3:-us-west-2}"
NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
PASS=0 FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ ${name}"
    ((PASS++))
  else
    echo "  ❌ ${name}"
    ((FAIL++))
  fi
}

echo "==> Verifying tenant: ${TENANT}"

# 1. Pod status
echo ""
echo "--- Pod ---"
check "Pod exists" kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o name
check "Pod ready" kubectl wait pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" --for=condition=Ready --timeout=10s

# 2. Service & Ingress
echo ""
echo "--- Network ---"
check "Service exists" kubectl get svc -n "${NAMESPACE}" "${RELEASE}"
check "Ingress exists" kubectl get httproute -n "${NAMESPACE}" "${RELEASE}"
check "NetworkPolicy exists" kubectl get networkpolicy -n "${NAMESPACE}" "${RELEASE}"

# 3. PVC
echo ""
echo "--- Storage ---"
check "PVC bound" bash -c "kubectl get pvc -n ${NAMESPACE} ${RELEASE} -o jsonpath='{.status.phase}' | grep -q Bound"

# 4. Pod Identity & Secrets Manager
echo ""
echo "--- IAM & Secrets ---"
check "ServiceAccount exists" kubectl get sa -n "${NAMESPACE}" "${RELEASE}"
check "Pod Identity association" aws eks list-pod-identity-associations --region "${REGION}" --cluster-name "${CLUSTER}" --namespace "${NAMESPACE}" --query 'associations[0].associationId' --output text
check "Secret accessible" aws secretsmanager get-secret-value --region "${REGION}" --secret-id "openclaw/${TENANT}/gateway-token" --query 'Name' --output text

# 5. Gateway health (port-forward + curl)
echo ""
echo "--- Gateway ---"
POD=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$POD" ]]; then
  kubectl port-forward -n "${NAMESPACE}" "${POD}" 28789:18789 &
  PF_PID=$!
  sleep 2
  check "Gateway responds" curl -sf http://127.0.0.1:28789/
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true
else
  echo "  ❌ Gateway (no pod found)"
  ((FAIL++))
fi

# 6. ResourceQuota & PDB
echo ""
echo "--- Policies ---"
check "ResourceQuota exists" kubectl get resourcequota -n "${NAMESPACE}"
check "PDB exists" kubectl get pdb -n "${NAMESPACE}" "${RELEASE}"

# Summary
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] && echo "🎉 Tenant ${TENANT} is healthy" || echo "⚠️  Tenant ${TENANT} has issues"
exit "$FAIL"
