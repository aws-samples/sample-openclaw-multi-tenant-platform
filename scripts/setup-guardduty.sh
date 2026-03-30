#!/usr/bin/env bash
set -euo pipefail

# Enable GuardDuty with EKS protection (account-level resource)
# Idempotent: skips if already enabled

REGION="${1:-us-west-2}"

echo "==> Checking GuardDuty status in ${REGION}"

DETECTOR_ID=$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null || echo "")

if [ -n "$DETECTOR_ID" ] && [ "$DETECTOR_ID" != "None" ]; then
  echo "  GuardDuty already enabled (detector: ${DETECTOR_ID})"
  echo "  Ensuring EKS protection is enabled..."
  aws guardduty update-detector \
    --detector-id "$DETECTOR_ID" \
    --features '[{"Name":"EKS_AUDIT_LOGS","Status":"ENABLED"},{"Name":"EKS_RUNTIME_MONITORING","Status":"ENABLED"}]' \
    --region "$REGION"
else
  echo "  Enabling GuardDuty with EKS protection..."
  DETECTOR_ID=$(aws guardduty create-detector \
    --enable \
    --features '[{"Name":"EKS_AUDIT_LOGS","Status":"ENABLED"},{"Name":"EKS_RUNTIME_MONITORING","Status":"ENABLED"}]' \
    --region "$REGION" \
    --query 'DetectorId' --output text)
fi

echo ""
echo "=== GuardDuty Enabled ==="
echo "  Detector ID: ${DETECTOR_ID}"
echo "  EKS Audit Logs: ENABLED"
echo "  EKS Runtime Monitoring: ENABLED"
echo "  Cost: ~\$4/month base + per-event"
echo "========================="
