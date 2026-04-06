#!/usr/bin/env bash
# Setup ArgoCD via Helm (self-managed).
#
# For production, consider migrating to EKS ArgoCD Capability (managed ArgoCD)
# which provides automatic upgrades and AWS Identity Center integration.
# See: https://docs.aws.amazon.com/eks/latest/userguide/argocd.html
#
# Usage: bash scripts/setup-argocd.sh
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

NAMESPACE="argocd"
RELEASE="argocd"

echo "==> Installing ArgoCD via Helm"

# Add Helm repo (idempotent)
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

# Install or upgrade (idempotent)
# TLS terminated at ALB/CloudFront — ArgoCD server runs behind cluster-internal ClusterIP
helm upgrade --install "${RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 300s \
  --set 'configs.params."server\.insecure"=true' \
  --set server.service.type=ClusterIP

echo "  Waiting for ArgoCD server..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n "${NAMESPACE}" --timeout=120s

echo "  ✅ ArgoCD installed"
echo ""
echo "  ArgoCD admin password:"
echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  For production, consider EKS ArgoCD Capability (managed):"
echo "    https://docs.aws.amazon.com/eks/latest/userguide/argocd.html"
