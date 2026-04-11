# 🚀 Minimal OpenClaw Deployment

The fastest way to deploy OpenClaw Platform with minimal configuration.

## ⚡ Quick Deploy (10 minutes)

```bash
# 1. Copy this example
cp -r examples/minimal-deployment my-openclaw
cd my-openclaw

# 2. Set your email domain
export ALLOWED_EMAIL_DOMAIN="your-company.com"

# 3. Deploy
./deploy.sh
```

## 📋 What Gets Deployed

**Core Components:**
- ✅ EKS Cluster (1 node, minimal capacity)
- ✅ Cognito User Pool (email verification)  
- ✅ CloudFront + S3 (Auth UI)
- ✅ ArgoCD (GitOps)
- ✅ KEDA (auto-scaling)

**Minimal Configuration:**
- 🚫 No custom domain (uses CloudFront URL)
- 🚫 No WAF protection  
- 🚫 No monitoring dashboards
- 🚫 No backup/retention policies
- 🚫 No multi-AZ redundancy

## 🔧 Configuration

### cdk.json (Minimal)
```json
{
  "app": "npx ts-node --prefer-ts-exts bin/cdk.ts",
  "context": {
    "allowedEmailDomains": "your-company.com",
    "githubOwner": "your-github-username", 
    "githubRepo": "sample-openclaw-multi-tenant-platform",
    "clusterName": "openclaw-minimal",
    "selfSignupEnabled": true,
    "enableWaf": false,
    "enableMonitoring": false,
    "nodeCapacity": {
      "desired": 1,
      "min": 1, 
      "max": 3
    }
  }
}
```

## 💰 Cost Estimate

**Monthly AWS Costs (us-east-1):**
- EKS Cluster: $73/month (control plane)
- EC2 Instances: ~$25/month (t3.medium)  
- CloudFront: ~$1/month (low traffic)
- Other Services: ~$10/month
- **Total: ~$109/month**

**Usage-Based Costs:**
- Bedrock (Claude): $0.008/1K input tokens
- Data Transfer: $0.09/GB after 1GB free

## ⚠️ Production Considerations

**NOT suitable for production:**
- Single point of failure (1 node)
- No disaster recovery
- Limited security (no WAF)
- No backup strategy
- No monitoring/alerting

**For production, see:**
- [examples/production-ready/](../production-ready/)
- [docs/operations/](../../docs/operations/)

## 🔍 Testing

### 1. Verify Deployment
```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name OpenClawEksStack-* \
  --query 'Stacks[0].StackStatus'

# Should return: CREATE_COMPLETE
```

### 2. Test Auth Flow
```bash
# Get Auth UI URL  
./get-auth-url.sh

# Open in browser, test sign up/sign in
```

### 3. Test AI Assistant
```bash
# Create test tenant
./scripts/create-tenant.sh testuser --email test@your-company.com

# Get tenant URL
echo "https://$(./get-domain.sh)/t/testuser/"
```

## 🧹 Cleanup

```bash
# Clean up everything
./cleanup.sh

# Verify cleanup
aws cloudformation list-stacks \
  --query 'StackSummaries[?contains(StackName,`OpenClaw`) && StackStatus!=`DELETE_COMPLETE`]'
```

## 🎯 Next Steps

1. **Test the platform** → Verify all functionality works
2. **Customize branding** → Update auth-ui/ assets  
3. **Add monitoring** → See [monitoring guide](../../docs/operations/monitoring.md)
4. **Plan production** → Review [production checklist](../../docs/operations/)
5. **Scale up** → Add more nodes, enable features

## 🆘 Troubleshooting

### Common Issues

**Issue:** Auth UI shows 404
```bash
# Solution: Wait for CloudFront propagation (up to 15 min)
curl -I $(./get-auth-url.sh)
```

**Issue:** Tenant workspace not ready
```bash  
# Solution: Check ArgoCD sync status
kubectl get applications -n argocd
kubectl logs -n argocd deployment/argocd-application-controller
```

**Issue:** High costs
```bash
# Solution: Check node utilization
kubectl top nodes
kubectl get pods --all-namespaces

# Scale down if needed
kubectl scale deployment --replicas=0 -n keda keda-operator
```

## 🔗 Related Examples

- [production-ready/](../production-ready/) - Multi-AZ, monitoring, backups
- [custom-domain/](../custom-domain/) - Route53 + ACM certificate setup
- [monitoring/](../monitoring/) - CloudWatch dashboards and alerts
- [multi-region/](../multi-region/) - Cross-region disaster recovery

## 📞 Support

- 📖 [Documentation](../../docs/)
- 🐛 [Report Issues](https://github.com/snese/sample-openclaw-multi-tenant-platform/issues)  
- 💬 [Discussions](https://github.com/snese/sample-openclaw-multi-tenant-platform/discussions)