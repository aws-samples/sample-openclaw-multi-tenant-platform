#!/usr/bin/env bash
set -euo pipefail

# Post-deploy script: adds ALB origin to the CDK-managed CloudFront distribution
# Run after: cdk deploy + deploy-platform.sh + setup-keda.sh
#
# The CDK CloudFront serves auth UI from S3 (default behavior) with a CloudFront
# Function for SPA routing. This script adds the ALB as a second origin:
#   CloudFront (claw.domain)
#     /        -> S3 (auth UI)        [CDK-managed, SPA rewrite via CF Function]
#     /t/*     -> ALB (tenant pods)   [added by this script]

source "$(dirname "$0")/lib/common.sh"

DOMAIN=$(get_output DomainName)
CUSTOM_DOMAIN=$(get_output CustomDomain)
WAF_ARN=$(get_output CloudFrontWafArn)

echo "==> Post-deploy setup"
echo "  Domain: $DOMAIN"
echo "  Custom domain: $CUSTOM_DOMAIN"

# 1. Find internet-facing ALB (created by ALB Controller when Gateway is reconciled)
# Use sort_by + [-1] to pick the most recently created ALB (handles orphans from prior deploys)
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "sort_by(LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')],&CreatedTime)[-1].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "sort_by(LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')],&CreatedTime)[-1].DNSName" --output text)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  echo "Error: Internet-facing ALB not found. Ensure deploy-platform.sh ran and at least one tenant exists."
  exit 1
fi
echo "  ALB: $ALB_DNS"

# 2. WAF is on CloudFront (managed by CDK custom resource). ALB WAF is optional — see docs/security.md.
echo "  CloudFront WAF: $WAF_ARN"

# 3. Find CDK-managed CloudFront distribution
if [ "$CUSTOM_DOMAIN" = "true" ]; then
  CF_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items[0]=='${DOMAIN}'].Id" --output text 2>/dev/null | head -1)
else
  # No custom domain — find by distribution domain name from stack output
  CF_DOMAIN_NAME=$(get_output DistributionDomainName)
  CF_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='${CF_DOMAIN_NAME}'].Id" --output text 2>/dev/null | head -1)
fi

if [ -z "$CF_ID" ]; then
  log_error "CloudFront distribution not found. Run 'cdk deploy' first."
  exit 1
fi
echo "  CloudFront: $CF_ID"

# Check if ALB origin already exists
EXISTING_ORIGINS=$(aws cloudfront get-distribution-config --id "$CF_ID" \
  --query "DistributionConfig.Origins.Items[*].Id" --output text)
if echo "$EXISTING_ORIGINS" | grep -q "alb"; then
  echo "  ALB origin already configured. Updating..."
fi

# 6. Add ALB origin + /t/* behavior to the existing CloudFront distribution
echo "  -> Adding ALB origin and /t/* behavior to CloudFront"

# Retry loop for ETag-based optimistic concurrency
MAX_RETRIES=3
for attempt in $(seq 1 $MAX_RETRIES); do
  aws cloudfront get-distribution-config --id "$CF_ID" > /tmp/cf-config-full.json
  ETAG=$(python3 -c "import json; print(json.load(open('/tmp/cf-config-full.json'))['ETag'])")

  python3 -c "
import json
import sys

try:
    with open('/tmp/cf-config-full.json') as f:
        full = json.load(f)
    config = full['DistributionConfig']

    alb_dns = '${ALB_DNS}'

    # Add ALB origin if not present
    origins = config['Origins']['Items']
    alb_origin_ids = [o['Id'] for o in origins if o['Id'] == 'alb']
    if not alb_origin_ids:
        origins.append({
            'Id': 'alb',
            'DomainName': alb_dns,
            'OriginPath': '',
            'CustomOriginConfig': {
                'HTTPPort': 80,
                'HTTPSPort': 443,
                'OriginProtocolPolicy': 'http-only' if '${CUSTOM_DOMAIN}' != 'true' else 'https-only',
                'OriginKeepaliveTimeout': 5,
                'OriginReadTimeout': 60,
                'OriginSslProtocols': {'Quantity': 1, 'Items': ['TLSv1.2']}
            },
            'CustomHeaders': {'Quantity': 0, 'Items': []},
            'OriginShield': {'Enabled': False},
            'ConnectionAttempts': 3,
            'ConnectionTimeout': 10,
        })
    else:
        for o in origins:
            if o['Id'] == 'alb':
                o['DomainName'] = alb_dns

    config['Origins']['Quantity'] = len(origins)

    # Add /t/* behavior if not present
    behaviors = config.get('CacheBehaviors', {}).get('Items', [])
    if not any(b['PathPattern'] == '/t/*' for b in behaviors):
        behaviors.append({
            'PathPattern': '/t/*',
            'TargetOriginId': 'alb',
            'ViewerProtocolPolicy': 'redirect-to-https',
            'Compress': True,
            'SmoothStreaming': False,
            'FieldLevelEncryptionId': '',
            'LambdaFunctionAssociations': {'Quantity': 0, 'Items': []},
            'FunctionAssociations': {'Quantity': 0, 'Items': []},
            'AllowedMethods': {
                'Quantity': 7,
                'Items': ['GET','HEAD','OPTIONS','PUT','POST','PATCH','DELETE'],
                'CachedMethods': {'Quantity': 2, 'Items': ['GET','HEAD']}
            },
            'CachePolicyId': '4135ea2d-6df8-44a3-9df3-4b5a84be39ad',
            'OriginRequestPolicyId': '216adef6-5c7f-47e4-b989-5492eafa07d3',
        })
    config['CacheBehaviors'] = {'Quantity': len(behaviors), 'Items': behaviors}

    # Remove any custom error responses (SPA routing now handled by CloudFront Function)
    config['CustomErrorResponses'] = {'Quantity': 0, 'Items': []}

    config['HttpVersion'] = 'http2and3'

    with open('/tmp/cf-config-update.json', 'w') as f:
        json.dump(config, f)

except Exception as e:
    print(f'Error modifying CloudFront config: {e}', file=sys.stderr)
    sys.exit(1)
"

  if aws cloudfront update-distribution --id "$CF_ID" \
    --if-match "$ETAG" \
    --distribution-config file:///tmp/cf-config-update.json \
    --query 'Distribution.{Status:Status,DomainName:DomainName}' --output json 2>/tmp/cf-update-error.log; then
    break
  fi

  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    log_error "CloudFront update failed after $MAX_RETRIES attempts"
    cat /tmp/cf-update-error.log >&2
    exit 1
  fi
  echo "  Retrying CloudFront update (attempt $((attempt+1))/$MAX_RETRIES)..."
  sleep 2
done
rm -f /tmp/cf-config-full.json /tmp/cf-config-update.json /tmp/cf-update-error.log

# Invalidate cached S3 responses for /t/* so the new ALB behavior takes effect immediately
aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/t/*" \
  --query 'Invalidation.Id' --output text > /dev/null
echo "  CloudFront updated + cache invalidated"

# 7. Update Route53 if using custom domain
if [ "$CUSTOM_DOMAIN" = "true" ]; then
  CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --query 'Distribution.DomainName' --output text)
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')
  echo "  -> Updating Route53 ${DOMAIN} -> $CF_DOMAIN"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
    \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
      \"Name\": \"${DOMAIN}\", \"Type\": \"A\",
      \"AliasTarget\": {\"HostedZoneId\": \"Z2FDTNDATAQYW2\", \"DNSName\": \"${CF_DOMAIN}\", \"EvaluateTargetHealth\": false}
    }}]
  }" > /dev/null
  echo "  Route53 updated"
else
  CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --query 'Distribution.DomainName' --output text)
  echo "  -> No custom domain. Access via CloudFront: https://${CF_DOMAIN}"
fi

# 9. Deploy auth UI config.js (Cognito values from stack outputs)
echo "  -> Deploying auth UI config.js"
POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)
AUTH_BUCKET=$(get_output AuthUiBucketName)
echo "var C={region:'${REGION}',userPoolId:'${POOL_ID}',clientId:'${CLIENT_ID}',domain:'${DOMAIN}'};" | \
  aws s3 cp - "s3://${AUTH_BUCKET}/config.js" --content-type "application/javascript" --region "$REGION"
echo "  config.js deployed"

echo ""
echo "=== Post-deploy complete ==="
echo "  Auth UI:    https://${DOMAIN}"
echo "  Tenants:    https://${DOMAIN}/t/<tenant>/"
echo "  CloudFront: ${CF_ID} (${CF_DOMAIN})"
echo "  ALB:        ${ALB_DNS} (CF-only SG)"
echo "  WAF:        CloudFront (edge)"
echo ""
echo "  CloudFront deployment takes ~3-5 min. Check status:"
echo "    aws cloudfront get-distribution --id ${CF_ID} --query 'Distribution.Status'"
echo "============================"
