## 📋 Summary

Brief description of what this PR accomplishes.

## 🎯 Type of Change

- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)  
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] 📚 Documentation update
- [ ] 🔧 Refactoring (no functional changes)
- [ ] 🧪 Test improvements
- [ ] 🚀 Performance improvement

## 🧪 Testing

### Manual Testing Checklist
- [ ] Deployment tested in us-east-1 (no domain)
- [ ] Deployment tested in us-west-2 (with domain) 
- [ ] Sign Up flow tested → receives "HIHI" message
- [ ] Sign In flow tested → workspace accessible
- [ ] Cleanup tested → all resources removed

### Automated Testing
- [ ] Unit tests pass (`npm test`)
- [ ] CDK synthesis passes (`npx cdk synth`) 
- [ ] Scripts pass shellcheck (`shellcheck scripts/*.sh`)
- [ ] Auth UI tests pass (`cd auth-ui && npm test`)

## 🔧 Infrastructure Changes

### AWS Resources Modified
- [ ] EKS Cluster configuration
- [ ] CloudFormation stack changes
- [ ] IAM roles/policies  
- [ ] CloudFront/S3 configuration
- [ ] Cognito User Pool settings
- [ ] Lambda functions
- [ ] Other: ________________

### Breaking Changes
If this PR introduces breaking changes, describe:
1. What breaks
2. How to migrate
3. Timeline for deprecation

## 📊 Performance Impact

- **Deployment Time:** Current vs New  
- **Resource Usage:** Memory/CPU impact
- **Cost Impact:** Any AWS cost changes
- **User Experience:** Latency/UX improvements

## 🔍 Review Focus Areas

Please pay special attention to:
- [ ] Security implications
- [ ] Performance impact  
- [ ] Error handling
- [ ] Documentation accuracy
- [ ] Backward compatibility

## 🔗 Related Issues

Fixes #(issue number)
Related to #(issue number)

## 📸 Screenshots (if applicable)

Before/After screenshots for UI changes.

## ✅ Deployment Verification

### Before Merging
- [ ] Changes tested in clean AWS account
- [ ] No CDK warnings or errors  
- [ ] All scripts execute successfully
- [ ] Documentation updated accordingly
- [ ] CHANGELOG.md updated (if applicable)

### Post-Merge Actions
- [ ] Monitor deployment metrics
- [ ] Update related documentation
- [ ] Notify stakeholders of changes

---

### 👥 Reviewers

@your-team - for architecture/security review
@[team-lead] - for feature completeness  
@[ops-team] - for operational concerns

### 📝 Additional Notes

Any additional context, concerns, or implementation details.