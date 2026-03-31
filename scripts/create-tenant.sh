#!/usr/bin/env bash
# Create a tenant by applying a Tenant CR. The Operator handles the rest.
# Usage: ./scripts/create-tenant.sh <name> [--email <email>] [--display-name <name>] [--budget <usd>] [--always-on]
set -euo pipefail

usage() {
  echo "Usage: $0 <tenant-name> [--email <email>] [--display-name <name>] [--budget <usd>] [--always-on]"
  exit 1
}

TENANT="" EMAIL="" DISPLAY_NAME="OpenClaw" BUDGET="100" ALWAYS_ON="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --always-on) ALWAYS_ON="true"; shift ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) TENANT="$1"; shift ;;
  esac
done

[[ -z "$TENANT" ]] && usage
[[ -z "$EMAIL" ]] && EMAIL="${TENANT}@example.com"

echo "Creating tenant: ${TENANT}"
echo "  Email:      ${EMAIL}"
echo "  Budget:     \$${BUDGET}/mo"
echo "  AlwaysOn:   ${ALWAYS_ON}"

kubectl apply -f - <<EOF
apiVersion: openclaw.io/v1alpha1
kind: Tenant
metadata:
  name: ${TENANT}
  namespace: openclaw-system
spec:
  email: "${EMAIL}"
  displayName: "${DISPLAY_NAME}"
  skills: [weather, gog]
  budget:
    monthlyUSD: ${BUDGET}
  enabled: true
  alwaysOn: ${ALWAYS_ON}
EOF

echo ""
echo "Tenant CR created. Operator will reconcile:"
echo "  kubectl get tenant ${TENANT} -w"
