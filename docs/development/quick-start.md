# ⚡ Quick Start Guide

Get OpenClaw Platform running in 15 minutes.

## 🎯 Prerequisites (2 minutes)

```bash
# Check dependencies
aws --version          # AWS CLI v2.0+
node --version         # Node.js 22+  
kubectl version        # kubectl 1.28+
helm version           # Helm 3.10+
docker --version       # Docker or finch
```

## 🚀 One-Command Deploy (12 minutes)

### 1. Clone and Configure
```bash
git clone https://github.com/snese/sample-openclaw-multi-tenant-platform
cd sample-openclaw-multi-tenant-platform

# Interactive configuration (30 seconds)
./scripts/lib/generate-config.sh
```

### 2. Deploy Everything
```bash
# Set Docker engine (if using finch)
export CDK_DOCKER=finch

# One-command deployment
./setup.sh --yes
```

**Progress Timeline:**
- ⏱️ 0-2min: Pre-flight checks and CDK synthesis
- ⏱️ 2-12min: Infrastructure creation (EKS cluster is the bottleneck)
- ⏱️ 12-14min: ArgoCD and platform services  
- ⏱️ 14-15min: KEDA and first tenant creation

### 3. Access Your Platform
```bash
# Get the Auth UI URL
aws cloudformation describe-stacks \
  --stack-name $(source scripts/lib/common.sh && echo $STACK) \
  --query 'Stacks[0].Outputs[?OutputKey==`AuthUiUrl`].OutputValue' \
  --output text
```

## 🎨 User Experience Test (1 minute)

1. **Open Auth UI** → Sign Up with your email
2. **Check Email** → Click verification link  
3. **Wait for "HIHI"** → Your AI assistant is ready!

## 🔧 Development Mode

### Local Development Setup
```bash
# Install hooks for better DX
./scripts/install-hooks.sh

# Enable debug mode
export OPENCLAW_DEBUG=true

# Hot reload for Auth UI changes
cd auth-ui && npm run dev
```

### Quick Testing
```bash
# Health check
./scripts/health-check.sh

# Create test tenant (bypasses Cognito)
./scripts/create-tenant.sh testuser --email test@example.com

# Run integration tests
npm test
```

## 🌐 Region-Specific Deployments

### us-east-1 (No Custom Domain)
```bash
ln -sf cdk-us-east-1.json cdk/cdk.json
export AWS_REGION=us-east-1
./setup.sh --yes
```

### us-west-2 (Custom Domain)
```bash
# First: Create ACM certificate for your domain
aws acm request-certificate --domain-name "*.yourdomain.com" --region us-west-2

# Update configuration
cp cdk.json.example cdk/cdk.json
# Edit: domainName, hostedZoneId, cloudfrontCertificateArn

./setup.sh --yes
```

## 🧹 Cleanup

### Quick Cleanup
```bash
# Delete specific deployment
./scripts/enhanced-force-cleanup.sh

# Clean up ALL OpenClaw resources (careful!)
./scripts/enhanced-force-cleanup.sh --region us-east-1
./scripts/enhanced-force-cleanup.sh --region us-west-2
```

### Verification
```bash
# Verify cleanup completed
aws cloudformation list-stacks --query 'StackSummaries[?contains(StackName,`OpenClaw`) && StackStatus!=`DELETE_COMPLETE`]'

# Should return empty array: []
```

## 🚨 Common Issues & Quick Fixes

### Issue: "DELETE_IN_PROGRESS" Error
```bash
# Solution: Dynamic stack naming (already implemented!)
# Each deployment gets unique name: OpenClawEksStack-2026-04-11T23-03-23
# No more conflicts!
```

### Issue: CDK Docker Error  
```bash
# Solution: Use finch or ensure Docker is running
export CDK_DOCKER=finch
# or
sudo systemctl start docker
```

### Issue: EKS Cluster Creation Timeout
```bash
# Check AWS service health
curl -s https://health.aws.amazon.com/health/status.json | jq '.services.EKS'

# Retry with different AZ
export CDK_FORCE_AZ="us-east-1a,us-east-1b"  
```

### Issue: Auth UI 404 Error
```bash
# Wait for CloudFront propagation (up to 15 minutes)
# Check deployment status:
aws cloudformation describe-stacks --stack-name $STACK_NAME \
  --query 'Stacks[0].StackStatus'
```

## 🎯 Performance Optimization

### Fast Development Cycle
```bash
# Skip resource-heavy components during development
export OPENCLAW_MINIMAL_MODE=true

# Use CDK hotswap for Lambda changes
cd cdk && npx cdk deploy --hotswap
```

### Production Deployment
```bash
# Full production deployment with monitoring
export OPENCLAW_PRODUCTION=true
export OPENCLAW_MONITORING=enabled
./setup.sh --yes
```

## 📖 Next Steps

| Goal | Documentation |
|------|---------------|
| **Understand Architecture** | [docs/architecture.md](../architecture.md) |
| **Add Custom Features** | [docs/development/](../development/) |
| **Production Setup** | [docs/operations/](../operations/) |
| **API Integration** | [docs/api/](../api/) |
| **Troubleshoot Issues** | [docs/troubleshooting.md](../troubleshooting.md) |

## 💡 Pro Tips

1. **Use Screen/Tmux** for long deployments
   ```bash
   screen -S openclaw-deploy
   ./setup.sh --yes
   # Ctrl+A, D to detach
   ```

2. **Monitor Progress** in separate terminal
   ```bash
   watch 'aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackStatus"'
   ```

3. **Parallel Deployments** in different regions
   ```bash
   # Terminal 1: us-east-1
   AWS_REGION=us-east-1 ./setup.sh --yes
   
   # Terminal 2: us-west-2  
   AWS_REGION=us-west-2 ./setup.sh --yes
   ```

4. **Save Deployment Info**
   ```bash
   # Auto-generated during deployment
   cat .openclaw-deployment
   # CDK_STACK_NAME=OpenClawEksStack-2026-04-11T23-03-23
   # REGION=us-east-1
   ```

**🎉 That's it! You now have a fully functional OpenClaw Platform with AI-powered multi-tenant workspaces.**