# Troubleshooting Guide

Common issues encountered when deploying and operating the OpenClaw Platform.

---

## Deployment Issues

### User signed up but no workspace appears

The PostConfirmation Lambda may have failed partway through. The user exists in Cognito but has no tenant resources.

**Diagnose:**
```bash
# Check if ApplicationSet element exists
kubectl get tenant -n openclaw-system | grep <tenant-id>

# Check Lambda logs
aws logs tail /aws/lambda/OpenClaw-PostConfirmation --since 1h --region us-west-2
```

**Fix:** Run the manual provisioning script:
```bash
./scripts/provision-tenant.sh <tenant-id> <email> [cognito-username]
```

See `scripts/provision-tenant.sh` for details and prerequisites.

### CDK deploy fails with "Resource already exists"

**Symptom**: `cdk deploy` fails on second run.

**Cause**: Some resources (Route53 records, CloudFront distributions) are created by `post-deploy.sh`, not CDK. CDK doesn't know about them.

**Fix**: Delete the conflicting resource manually, then re-run `cdk deploy`.

---
## KEDA / Scale-to-Zero Issues

### Pods stuck at 0 replicas, never scale up

**Symptom**: Tenant deployment has 0 replicas. HTTP requests return 503. KEDA interceptor logs show zero traffic.

**Cause**: Missing TargetGroupConfiguration for KEDA interceptor in `keda` namespace. Without it, ALB controller defaults to Instance target type, but the interceptor Service is ClusterIP.

**Fix**: The interceptor TGC is created by setup-keda.sh. Verify it exists:
```bash
kubectl get targetgroupconfiguration -n keda
# Should show: keda-interceptor-tg
```

If missing, check setup-keda.sh ran correctly:
```bash
kubectl get clusterrole applicationset -o yaml | grep targetgroupconfigurations
```

---

### ALB controller stuck in error loop: "TargetGroup port is empty"

**Symptom**: ALB controller logs show repeated `TargetGroup port is empty. When using Instance targets, your service must be of type 'NodePort' or 'LoadBalancer'`.

**Cause**: Same as above — missing interceptor TGC. This error blocks the entire Gateway reconcile, affecting ALL tenants.

**Fix**: Ensure the setup-keda.sh creates `targetgroupconfigurations` and is running the latest image.

---

### ArgoCD permanently OutOfSync on Deployment replicas

**Symptom**: ArgoCD shows Deployment as OutOfSync. Tenant stays in Provisioning.

**Cause**: KEDA modifies `spec.replicas` at runtime. ArgoCD sees the diff.

**Fix**: The ApplicationSet sets `ignoreDifferences` for `/spec/replicas` on Deployments and `/spec/defaultConfiguration/healthCheckConfig/healthCheckInterval` on TargetGroupConfigurations. Verify the ArgoCD Application has these:
```bash
kubectl get application tenant-<name> -n argocd -o jsonpath='{.spec.ignoreDifferences}' | python3 -m json.tool
```

---

### FailedCreatePodSandBox: aws-cni network policy error

**Symptom**: Pod events show `FailedCreatePodSandBox: plugin type="aws-cni" failed`.

**Cause**: Race condition — NetworkPolicy and Deployment are created simultaneously by ArgoCD. The VPC CNI network policy controller hasn't finished setting up the namespace.

**Fix**: The Helm chart sets `argocd.argoproj.io/sync-wave: "1"` on NetworkPolicy so it syncs after the Deployment. If you still see this, the pod will retry and succeed within ~15 seconds.

---

## Authentication Issues

### Sign Up succeeds but workspace never loads

**Symptom**: User completes email verification, sees "Creating your workspace..." spinner, but workspace never becomes reachable.

**Possible causes**:
1. **KEDA scale-from-zero broken** — see "Pods stuck at 0 replicas" above
2. **Lambda namespace race condition** — PostConfirmation Lambda creates K8s Secret before ApplicationSet manages namespace. Lambda retries with backoff (up to 5 attempts).
3. **Cognito triggers missing** — CDK Custom Resource should set PreSignUp + PostConfirmation triggers. Verify:
```bash
aws cognito-idp describe-user-pool --user-pool-id <pool-id> \
  --query 'UserPool.LambdaConfig' --output json
```

---

### Gateway token not working

**Symptom**: Workspace loads but shows authentication error.

**Cause**: Gateway token mismatch between Secrets Manager, K8s Secret, and Cognito user attribute.

**Fix**: Check all three sources match:
```bash
# Secrets Manager
aws secretsmanager get-secret-value --secret-id openclaw/<tenant>/gateway-token --query SecretString --output text

# K8s Secret
kubectl get secret <tenant>-gateway-token -n openclaw-<tenant> -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d

# Cognito (admin only)
aws cognito-idp admin-get-user --user-pool-id <pool-id> --username <email> \
  --query 'UserAttributes[?Name==`custom:gateway_token`].Value' --output text
```

---

## CI / Runner Issues

### GitHub Actions self-hosted runner offline

**Symptom**: CI jobs queued but not running. Runner shows "Offline" in GitHub Settings.

**Cause**: Runner service exited with `SessionConflictException` after EC2 restart. The old GitHub session hadn't expired when the new runner tried to connect.

**Fix**:
```bash
# Check runner status via SSM
aws ssm send-command --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo systemctl status actions.runner.*.service 2>&1 | tail -10"]' \
  --region us-east-1

# Restart runner service
aws ssm send-command --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo systemctl restart actions.runner.*.service"]' \
  --region us-east-1
```

**Prevention**: Consider adding `RestartForceExitStatus=5` to the systemd service to auto-restart on SessionConflict.

---
