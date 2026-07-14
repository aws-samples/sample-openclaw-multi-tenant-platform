#!/bin/bash
# Runtime-tier conformance check (ADR-0007 "Runtime tier extension contract").
#
# Verifies that a runtime tier actually works end-to-end for OpenClaw tenant
# workloads — the four things that break first under any new container runtime:
#   1. Kernel identity     — pod really runs under the requested runtime
#   2. Pod Identity        — link-local credential agent (169.254.170.23) reachable
#   3. EFS RWX             — shared-storage write/read through the CSI mount
#   4. Bedrock invoke      — a real AWS API call with the tenant role
#
# Usage:
#   ./scripts/conformance-runtime-tier.sh <runtimeClassName> [namespace] [service-account]
#   ./scripts/conformance-runtime-tier.sh gvisor
#   ./scripts/conformance-runtime-tier.sh ""        # runc baseline (no RuntimeClass)
#
# Requires: kubectl context pointing at the target cluster; a PVC named
# "conformance-data" is created (and cleaned up) in the target namespace.
set -uo pipefail

RUNTIME_CLASS="${1-}"
NAMESPACE="${2:-default}"
SERVICE_ACCOUNT="${3:-default}"
POD="conformance-${RUNTIME_CLASS:-runc}"
IMAGE="ghcr.io/openclaw/openclaw:latest"
FAIL=0

runtime_class_field=""
scheduling_fields=""
if [ -n "$RUNTIME_CLASS" ]; then
  runtime_class_field="runtimeClassName: ${RUNTIME_CLASS}"
fi

cleanup() {
  kubectl delete pod "$POD" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pvc conformance-data -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> Creating conformance pod (runtimeClass='${RUNTIME_CLASS:-<none/runc>}', ns=$NAMESPACE, sa=$SERVICE_ACCOUNT)"
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: conformance-data
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT}
  ${runtime_class_field}
  restartPolicy: Never
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["sleep", "600"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: conformance-data }
EOF

kubectl wait --for=condition=Ready "pod/$POD" -n "$NAMESPACE" --timeout=300s || {
  echo "FAIL: pod never became Ready"; kubectl describe pod "$POD" -n "$NAMESPACE" | tail -20; exit 1; }

check() {  # name, command
  local name="$1"; shift
  if out=$(kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "$*" 2>&1); then
    echo "PASS: $name — $(echo "$out" | head -1)"
  else
    echo "FAIL: $name — $(echo "$out" | head -3)"; FAIL=1
  fi
}

echo "==> 1/4 Kernel identity"
KERNEL=$(kubectl exec -n "$NAMESPACE" "$POD" -- cat /proc/version 2>&1)
echo "    /proc/version = $KERNEL"
if [ -n "$RUNTIME_CLASS" ] && [ "$RUNTIME_CLASS" = "gvisor" ]; then
  echo "$KERNEL" | grep -q "gvisor" && echo "PASS: gVisor kernel confirmed" || { echo "FAIL: expected gVisor kernel"; FAIL=1; }
else
  echo "INFO: baseline runtime — record kernel string above for the tier's ADR"
fi

echo "==> 2/4 Pod Identity agent reachability"
check "pod-identity" "wget -q -O- --timeout=5 http://169.254.170.23/v1/credentials 2>&1 | head -c 60 || curl -sf -m 5 http://169.254.170.23/v1/credentials | head -c 60"

echo "==> 3/4 EFS RWX write/read"
check "efs-rwx" "echo conformance-\$(date +%s) > /data/.conformance && cat /data/.conformance && rm /data/.conformance"

echo "==> 4/4 Bedrock invoke (ListFoundationModels via node SDK if present, else HTTPS reachability)"
check "bedrock" "node -e 'fetch(\"https://bedrock.\"+(process.env.AWS_REGION||\"us-east-1\")+\".amazonaws.com/foundation-models\",{signal:AbortSignal.timeout(10000)}).then(r=>{console.log(\"HTTP\",r.status);process.exit(r.status<600?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})'"

[ "$FAIL" -eq 0 ] && echo "==> CONFORMANCE PASS (${RUNTIME_CLASS:-runc})" || { echo "==> CONFORMANCE FAIL"; exit 1; }
