#!/usr/bin/env bash
# Install the kubernetes-sigs/agent-sandbox controller + CRDs.
#
# Adopts the agent-sandbox model (Sandbox / SandboxClaim / SandboxTemplate /
# SandboxWarmPool) used by awslabs/ai-on-eks. This script installs only the
# control plane (controller + CRDs); SandboxTemplates and per-tenant
# SandboxClaims are applied separately (see docs/agent-sandbox.md).
#
# Install commands follow the official guide:
#   https://agent-sandbox.sigs.k8s.io/docs/getting_started/install_prerequisites/
#
# Usage:
#   bash scripts/setup-agent-sandbox.sh            # install pinned version
#   bash scripts/setup-agent-sandbox.sh --dry-run  # print actions only
#   AGENT_SANDBOX_VERSION=latest bash scripts/setup-agent-sandbox.sh
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
require_cluster

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Pin by default for reproducible deploys; matches the ai-on-eks default.
# Set AGENT_SANDBOX_VERSION=latest to resolve the newest release at install time.
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.4.5}"

run() {
  echo "  → $*"
  $DRY_RUN || "$@"
}

echo "==> Installing agent-sandbox controller + CRDs"

if [[ "$AGENT_SANDBOX_VERSION" == "latest" ]]; then
  echo "  Resolving latest release tag from GitHub"
  if ! $DRY_RUN; then
    AGENT_SANDBOX_VERSION=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/agent-sandbox/releases/latest | jq -r '.tag_name')
  fi
fi
echo "  Version: ${AGENT_SANDBOX_VERSION}"

BASE_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}"

echo "  Step 1: Core components (controller + Sandbox CRD)"
run kubectl apply -f "${BASE_URL}/manifest.yaml"

echo "  Step 2: Extension CRDs (SandboxTemplate / SandboxClaim / SandboxWarmPool)"
run kubectl apply -f "${BASE_URL}/extensions.yaml"

echo "  Step 3: Wait for controller to be ready"
if ! $DRY_RUN; then
  kubectl -n agent-sandbox-system rollout status deploy --timeout=120s 2>/dev/null || true
  kubectl -n agent-sandbox-system get pods
fi

echo ""
echo "=== agent-sandbox installed (${AGENT_SANDBOX_VERSION}) ==="
echo "  Controller namespace: agent-sandbox-system"
echo "  Next: apply a SandboxTemplate, then migrate tenants to SandboxClaim."
echo "  See docs/agent-sandbox.md"
echo "================================================"
