#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing PVC backup CronJob"
kubectl apply -f "${SCRIPT_DIR}/pvc-backup-cronjob.yaml"

echo ""
echo "=== PVC Backup Installed ==="
echo "  Schedule: daily 03:00 UTC"
echo "  Retention: 7 days"
echo "  Manual run: kubectl create job --from=cronjob/openclaw-pvc-backup manual-backup -n kube-system"
echo "============================="
