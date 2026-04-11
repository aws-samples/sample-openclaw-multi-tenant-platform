# Troubleshooting Guide

Common issues encountered when deploying and operating the OpenClaw Platform.

---

## Deployment Issues

### Gateway stuck in Pending / Programmed: Unknown

**Symptom**: After running `deploy-platform.sh`, the Gateway never becomes `Programmed: True`. ALB is not created.

```bash
kubectl get gateway -n openclaw-system
# NAME               CLASS          ADDRESS   PROGRAMMED   AGE
# openclaw-gateway   openclaw-alb             Unknown      10m
```

**Possible causes**:

1. **Missing ListenerSet CRD**: ALB Controller v3.x requires a `ListenerSet` CRD in the GA API group (`gateway.networking.k8s.io/v1`). The `deploy-platform.sh` script creates this automatically. If you see `"Disabling ALBGatewayAPI: missing standard Gateway API CRDs"` in ALB Controller logs, the CRD installation failed.

2. **ALB Controller not restarted**: The controller checks for Gateway API CRDs only at startup. If CRDs were installed after the controller started, it won't detect them. `deploy-platform.sh` restarts the controller automatically, but if the restart failed:

```bash
# Check ALB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20 | grep -i gateway

# If you see "Disabling ALBGatewayAPI", restart the controller:
kubectl rollout restart deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl rollout status deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --timeout=120s
```

3. **RBAC missing for ListenerSet**: The controller needs permission to watch ListenerSet resources. Check for `"forbidden: cannot list resource listenersets"` in logs:

```bash
kubectl get clusterrolebinding alb-controller-listenerset
# If missing, re-run deploy-platform.sh
```

### User signed up but no workspace appears

The PostConfirmation AWS Lambda may have failed partway through. The user exists in Amazon Cognito but has no tenant resources.

**Diagnose:**
```bash
# Check if ApplicationSet element exists
kubectl get applicationset openclaw-tenants -n argocd -o json | python3 -c "import json,sys; [print(e['name']) for e in json.load(sys.stdin).get('spec',{}).get('generators',[{}])[0].get('list',{}).get('elements',[])]" | grep <tenant-id>

# Check AWS Lambda logs
aws logs tail /aws/lambda/OpenClaw-PostConfirmation --since 1h
```

**Fix:** Run the manual provisioning script:
```bash
./scripts/provision-tenant.sh <tenant-id> <email> [cognito-username]
```

See `scripts/provision-tenant.sh` for details and prerequisites.

### AWS CDK deploy fails with "Resource already exists"

**Symptom**: `cdk deploy` fails on second run.

**Cause**: Some resources (Route53 records, Amazon CloudFront distributions) are created by `post-deploy.sh`, not CDK. AWS CDK doesn't know about them.

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
2. **AWS Lambda namespace race condition** — PostConfirmation AWS Lambda creates K8s Secret before ApplicationSet manages namespace. AWS Lambda retries with backoff (up to 5 attempts).
3. **Amazon Cognito triggers missing** — AWS CDK Custom Resource should set PreSignUp + PostConfirmation triggers. Verify:
```bash
aws cognito-idp describe-user-pool --user-pool-id <pool-id> \
  --query 'UserPool.LambdaConfig' --output json
```

---

### Gateway token not working

**Symptom**: Workspace loads but shows authentication error.

**Cause**: Gateway token mismatch between Secrets Manager, K8s Secret, and Amazon Cognito user attribute.

**Fix**: Check all three sources match:
```bash
# Secrets Manager
aws secretsmanager get-secret-value --secret-id openclaw/<tenant>/gateway-token --query SecretString --output text

# K8s Secret
kubectl get secret <tenant>-gateway-token -n openclaw-<tenant> -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d

# Amazon Cognito (admin only)
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

---

## Destroy / Redeploy Issues

### `cdk destroy` takes a long time (30+ minutes)

**Cause**: AWS CDK's KubectlHandler AWS Lambda tries to `kubectl delete` K8s resources, but may lose network connectivity if VPC/NAT is deleted first. Each Custom Resource can hang up to 1 hour.

**Fix**: This is mitigated by `removalPolicy: RETAIN` on KubernetesManifest resources (PR #311). If you still see hangs on older deployments, use `--retain-resources` to skip stuck resources:

```bash
aws cloudformation delete-stack --stack-name OpenClawEksStack \
  --retain-resources <stuck-resource-1> <stuck-resource-2>
```

### `cdk deploy` fails with "already exists" after failed destroy

**Symptom**: `cdk deploy` fails with `Resource of type 'AWS::IAM::Role' with identifier '...' already exists`.

**Cause**: A previous deployment was destroyed incompletely (rollback, `--retain-resources`, or manual abort), leaving orphaned resources in the account. IAM roles created by AWS CDK use auto-generated names, but some resources (Amazon EKS cluster, Amazon Cognito triggers) may conflict.

**Fix**: Use the force-cleanup script to remove orphaned resources:
```bash
./scripts/force-cleanup.sh --delete
```

Then redeploy:
```bash
cd cdk && npx cdk deploy
```

### Amazon EKS nodegroup deletion takes 30+ minutes during rollback

**Symptom**: CloudFormation rollback or `cdk destroy` hangs on `AWS::EKS::Nodegroup` (Amazon EKS managed nodegroup) for 30 minutes.

**Cause**: Amazon EKS managed nodegroups have an ASG terminate lifecycle hook with a 30-minute heartbeat timeout. During deletion, the hook waits for a signal from the Amazon EKS service account. If the signal is delayed, deletion blocks until the timeout expires.

**Fix**: Delete the lifecycle hook to unblock:
```bash
# Find the ASG name
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'system')].AutoScalingGroupName" --output text)

# Delete the hook
aws autoscaling delete-lifecycle-hook \
  --lifecycle-hook-name Terminate-LC-Hook \
  --auto-scaling-group-name "$ASG_NAME"
```

This is normal Amazon EKS behavior and does not indicate a problem with the platform.

### VPC deletion blocked by GuardDuty managed security group

**Symptom**: CloudFormation rollback or `cdk destroy` hangs on `AWS::EC2::VPC` deletion. The VPC has a security group named `GuardDutyManagedSecurityGroup-vpc-xxxxx`.

**Cause**: If GuardDuty Amazon EKS Runtime Monitoring is enabled in the account, GuardDuty creates a managed security group in the Amazon EKS VPC. CloudFormation cannot delete it because it was not created by the stack.

**Fix**:
```bash
# Find the GuardDuty SG
VPC_ID=<your-vpc-id>
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" --query 'SecurityGroups[0].GroupId' --output text)

# Delete it
aws ec2 delete-security-group --group-id "$SG_ID"
```

### Retained resources after `cdk destroy`

Amazon EFS file systems and Amazon S3 error-page buckets are retained (data protection). They don't block redeployment but accumulate over multiple destroy/deploy cycles. See README "Cleanup" section for manual cleanup commands.

### Amazon EFS "Failed to locate a free GID"

If PVC creation fails with `Failed to locate a free GID for access point`, the Amazon EFS StorageClass GID range is exhausted. The AWS CDK stack configures `gidRangeStart: 1000` and `gidRangeEnd: 2000`, supporting up to 1000 tenants. If you hit this limit:

```bash
# Check current GID allocation
kubectl get sc efs-sc -o yaml | grep gid

# Expand range (edit StorageClass)
kubectl edit sc efs-sc
# Change gidRangeEnd to a higher value (e.g., 5000)
```

### Amazon CloudFront AWS WAF orphaned after `cdk destroy`

When the stack is deployed outside us-east-1, the Amazon CloudFront AWS WAF is created via `AwsCustomResource` in us-east-1. `cdk destroy` cannot automatically delete it (requires `LockToken` from a separate API call). Use `scripts/force-cleanup.sh` which handles AWS WAF cleanup, or manually delete:

```bash
# List WAFs in us-east-1
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1

# Delete (requires Id and LockToken from GetWebACL)
aws wafv2 get-web-acl --name OpenClaw-CF-WAF-us-west-2 --scope CLOUDFRONT --id <ID> --region us-east-1
aws wafv2 delete-web-acl --name OpenClaw-CF-WAF-us-west-2 --scope CLOUDFRONT --id <ID> --lock-token <TOKEN> --region us-east-1
```
