#!/usr/bin/env bash
# Check all tenants -- uses Tenant CR status (set by Operator)
# Usage: ./scripts/check-all-tenants.sh
set -euo pipefail

echo "=== Tenant Status ==="
kubectl get tenants -o wide 2>/dev/null || { echo "No tenants found or CRD not installed"; exit 0; }

echo ""
echo "=== Tenants Not Ready ==="
NOT_READY=$(kubectl get tenants -o jsonpath='{range .items[?(@.status.phase!="Ready")]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "$NOT_READY" ]]; then
  echo "All tenants are Ready"
else
  echo "$NOT_READY"
fi
