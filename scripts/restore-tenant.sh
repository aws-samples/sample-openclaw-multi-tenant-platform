#!/usr/bin/env bash
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-name> <s3-backup-path>}"
S3_PATH="${2:?Usage: $0 <tenant-name> <s3-backup-path>}"
NS="openclaw-${TENANT}"
POD_LABEL="app.kubernetes.io/instance=openclaw-${TENANT}"
LOCAL_FILE="/tmp/${TENANT}-restore.tar.gz"

# KEDA scale-to-zero: scale up if needed
SCALED_UP=false
if ! kubectl -n "$NS" get pods -l "$POD_LABEL" --field-selector=status.phase=Running -o name | grep -q .; then
  echo "==> Pod scaled to zero, scaling up..."
  kubectl -n "$NS" scale deployment "openclaw-${TENANT}" --replicas=1
  kubectl -n "$NS" rollout status deployment "openclaw-${TENANT}" --timeout=120s
  SCALED_UP=true
fi

POD=$(kubectl -n "$NS" get pods -l "$POD_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "==> Restoring tenant=${TENANT} pod=${POD} from ${S3_PATH}"

# Download from S3
aws s3 cp "$S3_PATH" "$LOCAL_FILE"

# Copy into pod
kubectl cp "$LOCAL_FILE" "${NS}/${POD}:/tmp/restore.tar.gz" -c main

# Extract
kubectl -n "$NS" exec "$POD" -c main -- tar xzf /tmp/restore.tar.gz -C /home/node/.openclaw

# Cleanup
kubectl -n "$NS" exec "$POD" -c main -- rm -f /tmp/restore.tar.gz
rm -f "$LOCAL_FILE"

echo "==> Restore complete for tenant=${TENANT}"
