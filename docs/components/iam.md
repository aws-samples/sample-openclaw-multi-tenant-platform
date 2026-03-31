# IAM and Tenant Isolation

Single shared IAM role for all tenants with ABAC to enforce per-tenant boundaries. Avoids one IAM role per tenant while maintaining strict isolation.

All IAM resources defined in `cdk/lib/eks-cluster-stack.ts`.

## Shared Tenant Role (ABAC)

`OpenClawTenantRole` -- assumed by `pods.eks.amazonaws.com` with `sts:TagSession`.

### How Pod Identity + ABAC Works

1. EKS Pod Identity Agent runs on every node
2. When a pod needs AWS credentials, the agent calls STS `AssumeRole` with session tag: `kubernetes-namespace = <pod's namespace>`
3. IAM policies use this tag in `Condition` blocks to scope access

Result: one IAM role for all tenants, isolation enforced at the policy level via session tags.

### Pod Identity Association

Created by PostConfirmation Lambda during tenant provisioning. Maps namespace `openclaw-{tenant}` + SA `{tenant}` to `OpenClawTenantRole`.

## Tenant Role Permissions

### Bedrock (Model Invocation)

`bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream` on all foundation models and inference profiles. Wildcard region for cross-region inference.

### Bedrock (Discovery)

`bedrock:ListFoundationModels`, `bedrock:ListInferenceProfiles`, `bedrock:GetInferenceProfile` on `*`.

### Secrets Manager (ABAC-scoped)

```
secretsmanager:GetSecretValue on *
Condition: secretsmanager:ResourceTag/tenant-namespace == ${aws:PrincipalTag/kubernetes-namespace}
```

Secrets tagged with `tenant-namespace=openclaw-{tenant}` at creation. Pod in `openclaw-alice` can only read secrets tagged `tenant-namespace=openclaw-alice`.

The fetch-secret script uses `TENANT_NAMESPACE` env var (Kubernetes downward API) to construct the secret path: `openclaw/{namespace}/{id}`.

### AgentCore Browser

`bedrock-agentcore:*BrowserSession*`, `bedrock-agentcore:*BrowserProfile*`, `bedrock-agentcore:ConnectBrowser*Stream` on `arn:aws:bedrock-agentcore:{region}:{account}:browser/*`.

## Other IAM Roles

| Role | Type | Purpose |
|------|------|---------|
| `EbsCsiDriverRole` | Pod Identity | EBS CSI driver (`AmazonEBSCSIDriverPolicy`) |
| `CwObservabilityRole` | Pod Identity | CloudWatch agent + X-Ray |
| LB Controller SA | IRSA | AWS Load Balancer Controller |
| Karpenter SA | IRSA | Karpenter controller |
| `KarpenterNodeRole` | EC2 instance role | Karpenter-launched nodes |
| `EbsSnapshotRole` | Pod Identity | PVC backup CronJob |

## Tenant Isolation Summary

| Layer | Mechanism | What it prevents |
|-------|-----------|-----------------|
| Kubernetes namespace | Each tenant in own namespace | Resource visibility isolation |
| NetworkPolicy | Egress blocks `10.0.0.0/8`, ingress same-NS only | Cross-tenant network traffic |
| IAM ABAC | `kubernetes-namespace` session tag in policy conditions | Cross-tenant AWS resource access |

All three layers must be breached for cross-tenant data access. Defense in depth.
