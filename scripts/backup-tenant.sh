#!/usr/bin/env bash
set -euo pipefail

TENANT="${1:?Usage: $0 <tenant-name> <s3-bucket>}"
BUCKET="${2:?Usage: $0 <tenant-name> <s3-bucket>}"
NS="tenant-${TENANT}"
POD_LABEL="app.kubernetes.io/instance=openclaw-${TENANT}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOCAL_FILE="/tmp/${TENANT}-${TIMESTAMP}.tar.gz"
S3_KEY="backups/${TENANT}/${TENANT}-${TIMESTAMP}.tar.gz"

# KEDA scale-to-zero: check if pod exists, scale up if needed
SCALED_UP=false
if ! kubectl -n "$NS" get pods -l "$POD_LABEL" --field-selector=status.phase=Running -o name | grep -q .; then
  echo "==> Pod scaled to zero, scaling up..."
  kubectl -n "$NS" scale deployment "openclaw-${TENANT}" --replicas=1
  kubectl -n "$NS" rollout status deployment "openclaw-${TENANT}" --timeout=120s
  SCALED_UP=true
fi

POD=$(kubectl -n "$NS" get pods -l "$POD_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "==> Backing up tenant=${TENANT} pod=${POD}"

# tar workspace inside pod
kubectl -n "$NS" exec "$POD" -c main -- tar czf /tmp/backup.tar.gz -C /home/node/.openclaw .

# copy out
kubectl cp "${NS}/${POD}:/tmp/backup.tar.gz" "$LOCAL_FILE" -c main

# cleanup pod tmp
kubectl -n "$NS" exec "$POD" -c main -- rm -f /tmp/backup.tar.gz

# upload to S3
aws s3 cp "$LOCAL_FILE" "s3://${BUCKET}/${S3_KEY}"
rm -f "$LOCAL_FILE"

echo "==> Backup complete: s3://${BUCKET}/${S3_KEY}"

# Scale back down if we scaled up
if [ "$SCALED_UP" = true ]; then
  echo "==> Scaling back to zero..."
  kubectl -n "$NS" scale deployment "openclaw-${TENANT}" --replicas=0
fi
