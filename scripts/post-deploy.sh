#!/usr/bin/env bash
set -euo pipefail

# Post-deploy script: sets up resources that depend on Kubernetes-managed ALB
# Run after: cdk deploy + setup-keda.sh + first tenant creation

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

DOMAIN=$(get_output DomainName)
WAF_ARN=$(get_output WafAclArn)
CF_CERT=$(get_output CloudFrontCertificateArn 2>/dev/null || echo "")

echo "==> Post-deploy setup"
echo "  Domain: $DOMAIN"

# 1. Find internal ALB (created by Kubernetes LB Controller)
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internal' && contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internal' && contains(LoadBalancerName,'openclaw')].DNSName" --output text)

if [ -z "$ALB_ARN" ]; then
  echo "Error: Internal ALB not found. Create at least one tenant first."
  exit 1
fi
echo "  ALB: $ALB_DNS (internal)"

# 2. Attach WAF to ALB
echo "  → Attaching WAF to ALB"
aws wafv2 associate-web-acl --web-acl-arn "$WAF_ARN" --resource-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true
echo "  ✅ WAF attached"

# 3. Create or find VPC Origin
VPC_ORIGIN_ID=$(aws cloudfront list-vpc-origins --query "VpcOriginList.Items[?VpcOriginEndpointConfig.Arn=='${ALB_ARN}'].Id" --output text 2>/dev/null)
if [ -z "$VPC_ORIGIN_ID" ]; then
  echo "  → Creating VPC Origin"
  VPC_ORIGIN_ID=$(aws cloudfront create-vpc-origin \
    --vpc-origin-endpoint-config "{\"Name\":\"openclaw-alb\",\"Arn\":\"${ALB_ARN}\",\"HTTPPort\":80,\"HTTPSPort\":443,\"OriginProtocolPolicy\":\"https-only\"}" \
    --query 'VpcOrigin.Id' --output text)
  echo "  Waiting for VPC Origin to deploy..."
  while [ "$(aws cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --query 'VpcOrigin.Status' --output text)" != "Deployed" ]; do
    sleep 15
  done
fi
echo "  ✅ VPC Origin: $VPC_ORIGIN_ID"

# 4. Create or find tenant CloudFront distribution (*.domain → VPC Origin → ALB)
TENANT_CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(to_string(Aliases.Items),'*.${DOMAIN}')].Id" --output text 2>/dev/null)

if [ -z "$TENANT_CF_ID" ]; then
  echo "  → Creating tenant CloudFront distribution"

  # Need us-east-1 cert ARN
  if [ -z "$CF_CERT" ]; then
    CF_CERT=$(aws acm list-certificates --region us-east-1 \
      --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn" --output text)
  fi

  cat > /tmp/tenant-cf.json << CFEOF
{
  "CallerReference": "openclaw-tenants-$(date +%s)",
  "Aliases": {"Quantity": 1, "Items": ["*.${DOMAIN}"]},
  "DefaultRootObject": "",
  "Origins": {"Quantity": 1, "Items": [{"Id": "alb", "DomainName": "${ALB_DNS}", "VpcOriginConfig": {"VpcOriginId": "${VPC_ORIGIN_ID}", "OriginKeepaliveTimeout": 5, "OriginReadTimeout": 60}, "CustomHeaders": {"Quantity": 0}, "OriginShield": {"Enabled": false}, "ConnectionAttempts": 3, "ConnectionTimeout": 10}]},
  "DefaultCacheBehavior": {"TargetOriginId": "alb", "ViewerProtocolPolicy": "redirect-to-https", "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"], "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}}, "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad", "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3", "Compress": true},
  "Comment": "OpenClaw tenants (*.${DOMAIN} → internal ALB)",
  "Enabled": true,
  "ViewerCertificate": {"ACMCertificateArn": "${CF_CERT}", "SSLSupportMethod": "sni-only", "MinimumProtocolVersion": "TLSv1.2_2021"},
  "HttpVersion": "http2and3",
  "PriceClass": "PriceClass_100"
}
CFEOF
  TENANT_CF_ID=$(aws cloudfront create-distribution --distribution-config file:///tmp/tenant-cf.json --query 'Distribution.Id' --output text)
  TENANT_CF_DOMAIN=$(aws cloudfront get-distribution --id "$TENANT_CF_ID" --query 'Distribution.DomainName' --output text)
else
  TENANT_CF_DOMAIN=$(aws cloudfront get-distribution --id "$TENANT_CF_ID" --query 'Distribution.DomainName' --output text)
fi
echo "  ✅ Tenant CloudFront: $TENANT_CF_ID ($TENANT_CF_DOMAIN)"

# 5. Update Route53 wildcard → tenant CloudFront
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')
echo "  → Updating Route53 *.${DOMAIN} → $TENANT_CF_DOMAIN"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
    \"Name\": \"*.${DOMAIN}\", \"Type\": \"A\",
    \"AliasTarget\": {\"HostedZoneId\": \"Z2FDTNDATAQYW2\", \"DNSName\": \"${TENANT_CF_DOMAIN}\", \"EvaluateTargetHealth\": false}
  }}]
}" > /dev/null
echo "  ✅ Route53 updated"

echo ""
echo "=== Post-deploy complete ==="
echo "  Auth UI:  https://${DOMAIN}"
echo "  Tenants:  https://<name>.${DOMAIN}"
echo "  ALB:      internal (${ALB_DNS})"
echo "  WAF:      attached"
echo "  VPC Origin: ${VPC_ORIGIN_ID}"
echo "============================"
