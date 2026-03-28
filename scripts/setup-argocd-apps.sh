#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Applying ArgoCD Applications (platform components)"
kubectl apply -f "$ROOT_DIR/argocd/applications/"

echo "==> Applying ArgoCD ApplicationSets (tenants)"
kubectl apply -f "$ROOT_DIR/argocd/applicationsets/"

echo ""
echo "=== ArgoCD Apps Applied ==="
echo "  Check status: kubectl get applications -n argocd"
echo "  Check sets:   kubectl get applicationsets -n argocd"
echo "==========================="
