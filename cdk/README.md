# OpenClaw CDK Infrastructure

Single AWS CDK stack (`OpenClawEksStack`) that provisions all infrastructure:

- Amazon VPC with VPC endpoints (S3 Gateway, ECR, STS)
- Amazon EKS cluster with Karpenter auto-scaling
- Amazon EFS for per-tenant persistent storage
- Amazon Cognito for user authentication (self-signup with email domain restriction)
- Amazon CloudFront with AWS WAF for edge protection
- AWS Lambda triggers for tenant provisioning
- Amazon CloudWatch alarms and Container Insights

## Usage

```bash
# Copy and configure
cp cdk.json.example cdk.json
# Edit cdk.json with your values

# Deploy
npx cdk deploy

# Destroy
npx cdk destroy
```

See the root [README.md](../README.md) for full deployment instructions.
