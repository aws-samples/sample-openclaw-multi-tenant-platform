#!/usr/bin/env bash
# Holmes rubric compliance checks — run in CI to catch findings early.
# Usage: bash scripts/check-rubric.sh
set -euo pipefail

FAILURES=0
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $1"; }

echo "==> Rubric compliance checks"

# 1. AWS Service Name Standards
echo ""
echo "--- AWS service names ---"
# Bare "Bedrock" (not "Amazon Bedrock") in docs
BARE_BEDROCK=$(grep -rn '\bBedrock\b' README.md docs/ AGENTS.md THREAT-MODEL.md --include="*.md" 2>/dev/null | grep -v "Amazon Bedrock\|bedrock-\|Bedrock-LLM\|/bedrock\|amazon-bedrock" || true)
if [ -n "$BARE_BEDROCK" ]; then
  fail "Bare 'Bedrock' found (use 'Amazon Bedrock'):"
  echo "$BARE_BEDROCK" | head -5
else
  pass "Amazon Bedrock naming"
fi

# Bare "WAF" (not "AWS WAF") in docs
BARE_WAF=$(grep -rn '\bWAF\b' README.md docs/ AGENTS.md THREAT-MODEL.md --include="*.md" 2>/dev/null | grep -v "AWS WAF\|WafAcl\|wafv2\|WAF->" || true)
if [ -n "$BARE_WAF" ]; then
  fail "Bare 'WAF' found (use 'AWS WAF'):"
  echo "$BARE_WAF" | head -5
else
  pass "AWS WAF naming"
fi

# 2. No placeholder content
echo ""
echo "--- Placeholder content ---"
PLACEHOLDERS=$(grep -rn "\[Your.*content here\]\|placeholder.*replace\|TODO.*replace\|FIXME.*content" auth-ui/ docs/ README.md --include="*.html" --include="*.md" 2>/dev/null || true)
if [ -n "$PLACEHOLDERS" ]; then
  fail "Placeholder content found:"
  echo "$PLACEHOLDERS" | head -5
else
  pass "No placeholder content"
fi

# 3. Superlative language
echo ""
echo "--- Superlative language ---"
SUPERLATIVES=$(grep -rni "seamlessly\|effortlessly\|cutting-edge\|state-of-the-art\|best-in-class\|world-class\|unparalleled" README.md docs/ AGENTS.md --include="*.md" 2>/dev/null || true)
if [ -n "$SUPERLATIVES" ]; then
  fail "Superlative language found:"
  echo "$SUPERLATIVES" | head -5
else
  pass "No superlative language"
fi

# 4. Stale architecture references
echo ""
echo "--- Stale references ---"
STALE=$(grep -rn "CloudFront #2\|VPC Origin\|--display-name\|--emoji\|setup-waf\.sh" README.md docs/ setup.sh AGENTS.md --include="*.md" --include="*.sh" 2>/dev/null || true)
if [ -n "$STALE" ]; then
  fail "Stale references found:"
  echo "$STALE" | head -5
else
  pass "No stale references"
fi

# 5. Compliance section wording
echo ""
echo "--- Compliance wording ---"
BAD_COMPLIANCE=$(grep -n "Readiness" docs/security.md 2>/dev/null | grep -i "SOC\|HIPAA\|PCI" || true)
if [ -n "$BAD_COMPLIANCE" ]; then
  fail "'Readiness' in compliance sections (use 'Technical Controls'):"
  echo "$BAD_COMPLIANCE"
else
  pass "Compliance wording correct"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "==> $FAILURES rubric check(s) failed"
  exit 1
else
  echo "==> All rubric checks passed"
fi
