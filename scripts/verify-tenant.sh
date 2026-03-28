#!/usr/bin/env bash
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-name> [other-tenant-name]}"
OTHER="${2:-}"
NAMESPACE="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ ${desc}"
    ((PASS++))
  else
    echo "  ❌ ${desc}"
    ((FAIL++))
  fi
}

check_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ❌ ${desc} (should have failed)"
    ((FAIL++))
  else
    echo "  ✅ ${desc}"
    ((PASS++))
  fi
}

echo "==> Verifying tenant: ${TENANT}"

# 1. Pod Running
echo ""
echo "--- Pod Status ---"
check "Pod is Running" \
  kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].status.phase}' | grep -q Running

POD=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# 2. Healthz
echo ""
echo "--- Health Check ---"
check "healthz returns 200" \
  kubectl exec -n "${NAMESPACE}" "${POD}" -- curl -sf http://127.0.0.1:18789/

# 3. ABAC isolation (requires a second tenant)
if [[ -n "${OTHER}" ]]; then
  OTHER_NS="openclaw-${OTHER}"
  OTHER_SECRET="openclaw/${OTHER}/gateway-token"

  echo ""
  echo "--- ABAC Isolation (${TENANT} → ${OTHER}) ---"
  check_fail "Cannot read ${OTHER}'s secret via ABAC" \
    kubectl exec -n "${NAMESPACE}" "${POD}" -- \
      node -e "
        const {SecretsManagerClient,GetSecretValueCommand}=require('@aws-sdk/client-secrets-manager');
        const c=new SecretsManagerClient({});
        c.send(new GetSecretValueCommand({SecretId:'${OTHER_SECRET}'})).then(()=>process.exit(0)).catch(()=>process.exit(1));
      "

  echo ""
  echo "--- NetworkPolicy Isolation (${TENANT} → ${OTHER}) ---"
  OTHER_SVC="openclaw-${OTHER}.${OTHER_NS}.svc.cluster.local"
  check_fail "Cannot reach ${OTHER}'s service" \
    kubectl exec -n "${NAMESPACE}" "${POD}" -- \
      curl -sf --connect-timeout 3 "http://${OTHER_SVC}:18789/"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit "${FAIL}"
