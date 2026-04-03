#!/usr/bin/env bash
# Check all tenants — reads ArgoCD Applications created by ApplicationSet
# Usage: ./scripts/check-all-tenants.sh
set -euo pipefail

echo "=== Tenant Applications ==="
kubectl get applications -n argocd -l openclaw.io/tenant -o custom-columns='TENANT:.metadata.labels.openclaw\.io/tenant,SYNC:.status.sync.status,HEALTH:.status.health.status,NAMESPACE:.spec.destination.namespace' 2>/dev/null || { echo "No tenant applications found"; exit 0; }

echo ""
echo "=== Not Healthy ==="
NOT_HEALTHY=$(kubectl get applications -n argocd -l openclaw.io/tenant -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for app in d.get('items', []):
    health = app.get('status', {}).get('health', {}).get('status', 'Unknown')
    if health != 'Healthy':
        name = app['metadata']['labels'].get('openclaw.io/tenant', app['metadata']['name'])
        sync = app.get('status', {}).get('sync', {}).get('status', 'Unknown')
        print(f'{name}\t{sync}\t{health}')
" 2>/dev/null || true)

if [[ -z "$NOT_HEALTHY" ]]; then
  echo "All tenants are Healthy"
else
  echo "$NOT_HEALTHY"
fi
