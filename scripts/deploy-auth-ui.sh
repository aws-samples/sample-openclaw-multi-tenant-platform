#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

BUCKET=$(get_output AuthUiBucketName)
POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)
DOMAIN=$(get_output DomainName)
TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-}"

if [ -z "$BUCKET" ]; then
  echo "Error: Could not find AuthUiBucketName in stack outputs. Run 'cdk deploy' first."
  exit 1
fi

echo "==> Deploying Auth UI"
echo "  Bucket:    $BUCKET"
echo "  Pool ID:   $POOL_ID"
echo "  Client ID: $CLIENT_ID"
echo "  Domain:    $DOMAIN"

# Inject config into HTML files
TMPDIR=$(mktemp -d)
INJECT="s|userPoolId: ''|userPoolId: '${POOL_ID}'|;s|clientId: ''|clientId: '${CLIENT_ID}'|;s|domain: ''|domain: '${DOMAIN}'|"

sed "${INJECT};s|turnstileSiteKey: ''|turnstileSiteKey: '${TURNSTILE_SITE_KEY}'|" \
  auth-ui/index.html > "${TMPDIR}/index.html"
sed "${INJECT}" auth-ui/admin.html > "${TMPDIR}/admin.html"
for f in auth-ui/*.html; do
  name="$(basename "$f")"
  [ "$name" = "index.html" ] || [ "$name" = "admin.html" ] && continue
  cp "$f" "${TMPDIR}/"
done
cp auth-ui/manifest.json "${TMPDIR}/"

# Upload
aws s3 sync "${TMPDIR}/" "s3://${BUCKET}/" --delete --content-type "text/html" --region "$REGION"
rm -rf "$TMPDIR"

CF_DOMAIN=$(get_output DistributionDomainName)
echo ""
echo "=== Auth UI Deployed ==="
echo "  S3:         s3://${BUCKET}/"
echo "  CloudFront: https://${CF_DOMAIN}"
echo ""
echo "  Next: Point Route53 ${DOMAIN} to CloudFront distribution"
echo "========================"
