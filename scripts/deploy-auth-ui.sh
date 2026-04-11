#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

BUCKET=$(get_output AuthUiBucketName)
POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)
DOMAIN=$(get_output DomainName)

if [ -z "$BUCKET" ]; then
  echo "Error: Could not find AuthUiBucketName in stack outputs. Run 'cdk deploy' first."
  exit 1
fi

echo "==> Deploying Auth UI"
echo "  Bucket:    $BUCKET"
echo "  Pool ID:   $POOL_ID"
echo "  Client ID: $CLIENT_ID"
echo "  Domain:    $DOMAIN"

# Generate config.js and copy static files
TMPDIR=$(mktemp -d)
echo "var C={region:'${REGION}',userPoolId:'${POOL_ID}',clientId:'${CLIENT_ID}',domain:'${DOMAIN}'};" > "${TMPDIR}/config.js"

# Copy all auth-ui files as-is (index.html loads config.js via <script src="/config.js">)
for f in auth-ui/*.html auth-ui/*.json auth-ui/*.svg; do
  [ -f "$f" ] && cp "$f" "${TMPDIR}/"
done

# Upload
aws s3 sync "${TMPDIR}/" "s3://${BUCKET}/" --delete --region "$REGION"
rm -rf "$TMPDIR"

CF_DOMAIN=$(get_output DistributionDomainName)
echo ""
echo "=== Auth UI Deployed ==="
echo "  S3:         s3://${BUCKET}/"
echo "  CloudFront: https://${CF_DOMAIN}"
if [[ -n "$DOMAIN" && "$DOMAIN" != "$CF_DOMAIN" ]]; then
  echo ""
  echo "  Next: Point Route53 ${DOMAIN} to CloudFront distribution"
fi
echo "========================"
