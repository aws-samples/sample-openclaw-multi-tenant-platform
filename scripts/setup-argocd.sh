#!/usr/bin/env bash
set -euo pipefail

echo "=== ArgoCD Login Info ==="

PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo "Username: admin"
echo "Password: $PASSWORD"

echo ""
echo "=== Access ArgoCD UI ==="
echo "Run: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then open: https://localhost:8080"
