#!/usr/bin/env bash
set -euo pipefail

# migrate-tenant-ebs-to-efs.sh — Migrate a tenant's data from EBS PVC to EFS.
#
# Safety guarantees:
#   - Old EBS PVC is NEVER deleted unless migration is fully verified
#   - Every failure path aborts with data intact + recovery instructions
#   - Job verifies: cp exit code + file count + total size
#
# Prerequisites:
#   - EFS CSI driver installed + efs-sc StorageClass exists
#   - kubectl configured for the EKS cluster
#
# Usage:
#   ./scripts/migrate-tenant-ebs-to-efs.sh <tenant-name>

TENANT="${1:?Usage: $0 <tenant-name>}"
NAMESPACE="openclaw-${TENANT}"
OLD_PVC="${TENANT}"
NEW_PVC="${TENANT}-efs"
JOB_NAME="migrate-${TENANT}"

echo "==> Migrating tenant: ${TENANT}"
echo "  Namespace: ${NAMESPACE}"
echo ""

# ── Step 1: Ensure no pods hold the PVC ──────────────────────────────────
POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ "${POD_COUNT}" -gt 0 ]]; then
  echo "⏳ Waiting for pods to fully terminate..."
  if ! kubectl wait --for=delete pod --all -n "${NAMESPACE}" --timeout=60s 2>/dev/null; then
    echo "❌ Pods still exist. Scale to 0 first:"
    echo "   kubectl scale deployment ${TENANT} -n ${NAMESPACE} --replicas=0"
    exit 1
  fi
fi
echo "  ✅ No pods in namespace"

# ── Step 2: Verify old PVC exists and is Bound ──────────────────────────
OLD_STATUS=$(kubectl get pvc "${OLD_PVC}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "${OLD_STATUS}" != "Bound" ]]; then
  echo "❌ Old PVC '${OLD_PVC}' not Bound (status: ${OLD_STATUS:-not found})"
  exit 1
fi
echo "  ✅ Old PVC Bound (storageClass: $(kubectl get pvc "${OLD_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.storageClassName}'))"

# ── Step 3: Create temporary EFS PVC ─────────────────────────────────────
echo "==> Creating temporary EFS PVC: ${NEW_PVC}"
# nosemgrep: bash.lang.correctness.useless-cat
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NEW_PVC}
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 10Gi
EOF

if ! kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/"${NEW_PVC}" -n "${NAMESPACE}" --timeout=60s; then
  echo "❌ EFS PVC failed to bind. Cleaning up."
  kubectl delete pvc "${NEW_PVC}" -n "${NAMESPACE}" --ignore-not-found --wait
  exit 1
fi
echo "  ✅ EFS PVC Bound"

# ── Step 4: Clean up any previous failed job ─────────────────────────────
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait 2>/dev/null

# ── Step 5: Run migration job ────────────────────────────────────────────
echo "==> Running migration job (cp + verify)"
# nosemgrep: bash.lang.correctness.useless-cat
cat <<'JOBEOF' | sed "s/\${OLD_PVC}/${OLD_PVC}/g; s/\${NEW_PVC}/${NEW_PVC}/g; s/\${JOB_NAME}/${JOB_NAME}/g; s/\${NAMESPACE}/${NAMESPACE}/g" | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: migrate
        image: ghcr.io/openclaw/openclaw:2026.3.24
        command: ["/bin/sh", "-e", "-c"]
        args:
        - |
          echo "=== Copying data ==="
          cp -a /old/. /new/
          echo "=== Verifying ==="
          OLD_COUNT=$(find /old | wc -l)
          NEW_COUNT=$(find /new | wc -l)
          OLD_SIZE=$(du -sb /old | cut -f1)
          NEW_SIZE=$(du -sb /new | cut -f1)
          echo "Files: old=${OLD_COUNT} new=${NEW_COUNT}"
          echo "Bytes: old=${OLD_SIZE} new=${NEW_SIZE}"
          if [ "${OLD_COUNT}" -ne "${NEW_COUNT}" ]; then
            echo "FAIL: file count mismatch"; exit 1
          fi
          if [ "${NEW_SIZE}" -lt "${OLD_SIZE}" ]; then
            echo "FAIL: new smaller than old"; exit 1
          fi
          echo "MIGRATION_OK"
        volumeMounts:
        - name: old-data
          mountPath: /old
          readOnly: true
        - name: new-data
          mountPath: /new
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { cpu: 500m, memory: 256Mi }
      volumes:
      - name: old-data
        persistentVolumeClaim:
          claimName: ${OLD_PVC}
      - name: new-data
        persistentVolumeClaim:
          claimName: ${NEW_PVC}
JOBEOF

echo "  Waiting for job (timeout 5m)..."
if ! kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "${NAMESPACE}" --timeout=300s; then
  echo "❌ Migration job failed or timed out."
  echo "  Logs:  kubectl logs job/${JOB_NAME} -n ${NAMESPACE}"
  echo "  Retry: kubectl delete job ${JOB_NAME} -n ${NAMESPACE} && re-run this script"
  echo "  Abort: kubectl delete job ${JOB_NAME} pvc/${NEW_PVC} -n ${NAMESPACE}"
  echo "  ⚠️  Old EBS PVC is untouched — no data lost."
  exit 1
fi

# ── Step 6: Triple-verify before any deletion ────────────────────────────
JOB_SUCCEEDED=$(kubectl get job "${JOB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
if [[ "${JOB_SUCCEEDED}" != "1" ]]; then
  echo "❌ Job status.succeeded != 1. Aborting — no data deleted."
  exit 1
fi

LAST_LINE=$(kubectl logs job/"${JOB_NAME}" -n "${NAMESPACE}" --tail=1 2>/dev/null || echo "LOG_RETRIEVAL_FAILED")
if [[ "${LAST_LINE}" != "MIGRATION_OK" ]]; then
  echo "❌ Log verification failed (got: '${LAST_LINE}'). Aborting — no data deleted."
  exit 1
fi

echo "  ✅ Migration verified"
kubectl logs job/"${JOB_NAME}" -n "${NAMESPACE}" 2>/dev/null | grep -E 'Files:|Bytes:' || true

# ── Step 7: Delete old EBS PVC ───────────────────────────────────────────
echo "==> Deleting old EBS PVC: ${OLD_PVC}"
kubectl delete pvc "${OLD_PVC}" -n "${NAMESPACE}" --wait

# ── Step 8: Cleanup temp resources ───────────────────────────────────────
echo "==> Cleaning up"
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait 2>/dev/null
kubectl delete pvc "${NEW_PVC}" -n "${NAMESPACE}" --ignore-not-found --wait 2>/dev/null

echo ""
echo "=== Migration Complete ==="
echo "  ✅ Old EBS PVC deleted"
echo "  ✅ Temp EFS PVC deleted"
echo "  → ArgoCD will create new EFS PVC '${OLD_PVC}' on next sync"
echo "  → Verify: kubectl get pvc -n ${NAMESPACE}"
