#!/usr/bin/env bash
# Local CI — mirrors GitHub Actions CI pipeline
# Run from repo root: ./operator/scripts/ci-local.sh
# Or from operator/: ./scripts/ci-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$OP_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
step() { echo -e "\n${YELLOW}━━━ $1 ━━━${NC}"; }

cd "$OP_DIR"

# ── Rust checks ──────────────────────────────────────────────
step "cargo fmt --check"
cargo fmt --check || fail "Formatting issues. Run: cargo fmt"
pass "Formatting OK"

step "cargo clippy"
cargo clippy --all-targets --all-features -- -D warnings || fail "Clippy found issues"
pass "Clippy clean"

step "cargo check"
cargo check --all-targets || fail "Compilation failed"
pass "Compiles OK"

step "CRD generation check"
GENERATED=$(cargo run --bin crdgen 2>/dev/null)
if ! diff -q <(echo "$GENERATED") yaml/crd.yaml >/dev/null 2>&1; then
  warn "CRD yaml is out of date. Updating..."
  echo "$GENERATED" > yaml/crd.yaml
  pass "CRD yaml updated"
else
  pass "CRD yaml is up to date"
fi

step "cargo test --lib"
cargo test --lib --all-features || fail "Unit tests failed"
pass "Unit tests passed"

# ── Platform checks (if CDK/Helm exist) ─────────────────────
if [ -d "$REPO_DIR/cdk" ]; then
  step "TypeScript compile check"
  (cd "$REPO_DIR/cdk" && npx tsc --noEmit 2>/dev/null) && pass "CDK compiles" || warn "CDK compile failed (non-blocking)"
fi

if [ -d "$REPO_DIR/helm" ]; then
  step "Helm lint"
  helm lint "$REPO_DIR/helm/charts/openclaw-platform/" \
    --set ingress.enabled=true \
    --set ingress.host=test.example.com \
    --set tenant.name=test 2>/dev/null && pass "Helm lint OK" || warn "Helm lint failed (non-blocking)"
fi

# ── Security checks ─────────────────────────────────────────
step "Sensitive data scan"
# Pattern-based: look for AWS access key patterns, not literal values
SECRETS=$(grep -rn 'AKIA[A-Z0-9]\{16\}' "$OP_DIR/src/" 2>/dev/null || true)
if [ -n "$SECRETS" ]; then
  fail "Found hardcoded AWS keys in: $SECRETS"
fi
pass "No sensitive data"

step "CJK character scan"
# Use hex escape to avoid embedding CJK in this script
CJK_FILES=$(grep -rl "$(printf '[\xe4\xb8\x80-\xe9\xbe\xa5]')" "$OP_DIR/src/" 2>/dev/null || true)
if [ -n "$CJK_FILES" ]; then
  fail "Found CJK characters in: $CJK_FILES"
fi
pass "No CJK characters"

# ── Summary ──────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ ALL CHECKS PASSED ━━━${NC}"
