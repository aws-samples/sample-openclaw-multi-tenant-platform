#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing image update CronJob"
kubectl apply -f "${SCRIPT_DIR}/image-update-cronjob.yaml"

echo ""
echo "=== Image Updater Installed ==="
echo "  Schedule: every 6 hours"
echo "  Namespace: kube-system"
echo "  Manual run: kubectl create job --from=cronjob/openclaw-image-updater manual-update -n kube-system"
echo "==============================="
