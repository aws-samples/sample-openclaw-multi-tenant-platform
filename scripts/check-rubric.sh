#!/usr/bin/env bash
# Rubric compliance checks — run in CI to catch common documentation issues.
# Usage: bash scripts/check-rubric.sh
#
# Checks:
#   1. AWS service name standards (full names in prose)
#   2. No placeholder content
#   3. No superlative language
#   4. No stale architecture references
#   5. Compliance section wording
#   6. Security claim qualifiers
set -euo pipefail

FAILURES=0
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $1"; }

PROSE_FILES="README.md docs/ AGENTS.md THREAT-MODEL.md CONTRIBUTING.md"
PROSE_INCLUDE='--include=*.md'

echo "==> Rubric compliance checks"

# ── 1. AWS Service Name Standards ────────────────────────────────────────
echo ""
echo "--- AWS service names ---"

# Each entry: "bare_name:full_name:extra_excludes"
SERVICE_NAMES=(
  "Bedrock:Amazon Bedrock:bedrock-|Bedrock-LLM|/bedrock|amazon-bedrock"
  "WAF:AWS WAF:WafAcl|wafv2|WAF->"
  "EKS:Amazon EKS:aws-eks|eks\.|/eks/|EKS-|badge|logo"
  "S3:Amazon S3:s3\.|/s3/|s3:|S3-|s3api|s3deploy|s3bucket"
  "EFS:Amazon EFS:efs\.|/efs/|EFS-|EfsCsi|EfsStorage|EfsMountTarget|EfsSecurityGroup|EfsFileSystem"
  "CloudFront:Amazon CloudFront:cloudfront\.|CloudFrontCertificate|CloudFrontWebDistribution|CloudFront-|cloudfront:"
  "Cognito:Amazon Cognito:cognito-|cognito\.|/cognito/|CognitoPool|CognitoClient|CognitoDomain|CognitoTriggers|CognitoCustom|CognitoInvoke"
  "Lambda:AWS Lambda:lambda\.|/lambda/|LambdaConfig|LambdaFunction|lambda:|Lambda-"
  "CDK:AWS CDK:cdk\.|/cdk/|CDKToolkit|CDKMetadata|CDKBucket|cdk-nag|cdk\.json|aws-cdk|CDK-|npx cdk"
)

for entry in "${SERVICE_NAMES[@]}"; do
  IFS=':' read -r BARE FULL EXCLUDES <<< "$entry"
  EXCLUDE_PATTERN="${FULL}|${EXCLUDES}"
  # Search prose files, exclude full name and code patterns, exclude diagram lines
  FOUND=$(grep -rn "\b${BARE}\b" $PROSE_FILES $PROSE_INCLUDE 2>/dev/null \
    | grep -vE "$EXCLUDE_PATTERN" | grep -v "❌\|\`.*\b'${BARE}'\b.*\`" \
    | grep -v "[-=]>.*${BARE}\|${BARE}.*[-=]>" \
    || true)
  if [ -n "$FOUND" ]; then
    fail "Bare '${BARE}' found (use '${FULL}'):"
    echo "$FOUND" | head -3
  else
    pass "${FULL} naming"
  fi
done

# ── 2. No placeholder content ────────────────────────────────────────────
echo ""
echo "--- Placeholder content ---"
PLACEHOLDERS=$(grep -rn "\[Your.*content here\]" auth-ui/ docs/ README.md --include="*.html" --include="*.md" 2>/dev/null || true)
if [ -n "$PLACEHOLDERS" ]; then
  fail "Placeholder content found:"
  echo "$PLACEHOLDERS" | head -5
else
  pass "No placeholder content"
fi

# ── 3. Superlative language ──────────────────────────────────────────────
echo ""
echo "--- Superlative language ---"
SUPERLATIVES=$(grep -rni "seamlessly\|effortlessly\|cutting-edge\|state-of-the-art\|best-in-class\|world-class\|unparalleled" README.md docs/ AGENTS.md $PROSE_INCLUDE 2>/dev/null || true)
if [ -n "$SUPERLATIVES" ]; then
  fail "Superlative language found:"
  echo "$SUPERLATIVES" | head -5
else
  pass "No superlative language"
fi

# ── 4. Stale architecture references ─────────────────────────────────────
echo ""
echo "--- Stale references ---"
STALE=$(grep -rn "CloudFront #2\|VPC Origin\|--display-name\|--emoji\|setup-waf\.sh" README.md docs/ setup.sh AGENTS.md $PROSE_INCLUDE --include="*.sh" 2>/dev/null || true)
if [ -n "$STALE" ]; then
  fail "Stale references found:"
  echo "$STALE" | head -5
else
  pass "No stale references"
fi

# ── 5. Compliance section wording ────────────────────────────────────────
echo ""
echo "--- Compliance wording ---"
BAD_COMPLIANCE=$(grep -n "Readiness" docs/security.md 2>/dev/null | grep -i "SOC\|HIPAA\|PCI" || true)
if [ -n "$BAD_COMPLIANCE" ]; then
  fail "'Readiness' in compliance sections (use 'Technical Controls'):"
  echo "$BAD_COMPLIANCE"
else
  pass "Compliance wording correct"
fi

# ── 6. Unqualified security claims ───────────────────────────────────────
echo ""
echo "--- Security claim qualifiers ---"
# "ensures" without "designed to" qualifier in security docs
UNQUALIFIED=$(grep -n "\bensures\b" docs/security.md THREAT-MODEL.md 2>/dev/null | grep -v "designed to ensure\|configured to ensure" || true)
if [ -n "$UNQUALIFIED" ]; then
  fail "Unqualified 'ensures' (use 'designed to ensure'):"
  echo "$UNQUALIFIED" | head -3
else
  pass "Security claims qualified"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "==> $FAILURES rubric check(s) failed"
  exit 1
else
  echo "==> All rubric checks passed"
fi
