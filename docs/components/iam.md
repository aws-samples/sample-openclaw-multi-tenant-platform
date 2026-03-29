# IAM and Tenant Isolation

The OpenClaw platform uses a single shared IAM role for all tenants, with Attribute-Based Access Control (ABAC) to enforce per-tenant boundaries. This avoids creating one IAM role per tenant while maintaining strict isolation.

All IAM resources are defined in `cdk/lib/eks-cluster-stack.ts`.

## Shared Tenant Role (ABAC)

```typescript
// cdk/lib/eks-cluster-stack.ts — "Shared Tenant IAM Role" section
const tenantRole = new iam.Role(this, 'TenantRole', {
  roleName: 'OpenClawTenantRole',
  assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
  description: 'Shared IAM role for all OpenClaw tenant pods (ABAC via EKS Pod Identity)',
});
tenantRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
  actions: ['sts:TagSession'],
  principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
}));
```

### How Pod Identity + ABAC Works

1. **EKS Pod Identity Agent** (installed as add-on) runs on every node
2. When a pod needs AWS credentials, the agent calls STS `AssumeRole` with a **session tag**: `kubernetes-namespace = <pod's namespace>`
3. The resulting temporary credentials carry `aws:PrincipalTag/kubernetes-namespace`
4. IAM policies use this tag in `Condition` blocks to scope access

This means:
- One IAM role for all tenants (no role-per-tenant sprawl)
- Tenant isolation is enforced at the IAM policy level via session tags
- A pod in namespace `openclaw-alice` can only access resources tagged `tenant-namespace=openclaw-alice`

### Pod Identity Association

Created by the `PostConfirmFn` Lambda during tenant provisioning:

```typescript
// cdk/lib/eks-cluster-stack.ts — "Lambda: Post-Confirmation" section
postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
  actions: ['eks:CreatePodIdentityAssociation'],
  resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${cluster.clusterName}`],
}));
```

Each tenant gets a Pod Identity Association mapping their namespace's service account to `OpenClawTenantRole`.

## Tenant Role Permissions

### Bedrock (Model Invocation)

```typescript
tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
  sid: 'BedrockInvoke',
  actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
  resources: [
    'arn:aws:bedrock:*::foundation-model/*',
    `arn:aws:bedrock:*:${this.account}:inference-profile/*`,
  ],
}));
```

- Wildcard region (`*`) because US inference profiles route cross-region
- No ABAC needed — Bedrock models are shared resources, not tenant-scoped

### Bedrock (Discovery)

```typescript
tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
  sid: 'BedrockDiscovery',
  actions: ['bedrock:ListFoundationModels', 'bedrock:ListInferenceProfiles', 'bedrock:GetInferenceProfile'],
  resources: ['*'],
}));
```

### Secrets Manager (ABAC-scoped)

```typescript
tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
  sid: 'SecretsManagerABAC',
  actions: ['secretsmanager:GetSecretValue'],
  resources: ['*'],
  conditions: {
    StringEquals: {
      'secretsmanager:ResourceTag/tenant-namespace': '${aws:PrincipalTag/kubernetes-namespace}',
    },
  },
}));
```

This is the core ABAC mechanism:
- Secrets are tagged with `tenant-namespace=<namespace>` at creation time (by `PostConfirmFn`)
- The policy condition compares the secret's tag against the pod's session tag
- A pod in `openclaw-alice` can only read secrets tagged `tenant-namespace=openclaw-alice`

Secret naming convention: `openclaw/<namespace>/<secret-id>`

The fetch-secret script in the Helm chart (`values.yaml` → `fetchSecret`) uses this pattern:

```javascript
// helm/charts/openclaw-platform/values.yaml — fetchSecret
const ns = process.env.TENANT_NAMESPACE;  // injected from metadata.namespace
const { SecretString } = await sm.send(
  new GetSecretValueCommand({ SecretId: `openclaw/${ns}/${id}` })
);
```

The `TENANT_NAMESPACE` env var is set from the Kubernetes downward API:

```yaml
# helm/charts/openclaw-platform/templates/deployment.yaml
env:
  - name: TENANT_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
```

### AgentCore Browser

```typescript
tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
  sid: 'AgentCoreBrowser',
  actions: [
    'bedrock-agentcore:StartBrowserSession',
    'bedrock-agentcore:StopBrowserSession',
    'bedrock-agentcore:GetBrowserSession',
    'bedrock-agentcore:ListBrowserSessions',
    'bedrock-agentcore:ConnectBrowserAutomationStream',
    'bedrock-agentcore:ConnectBrowserLiveViewStream',
    'bedrock-agentcore:GetBrowserProfile',
    'bedrock-agentcore:SaveBrowserSessionProfile',
  ],
  resources: [`arn:aws:bedrock-agentcore:${this.region}:${this.account}:browser/*`],
}));
```

## Other IAM Roles

These are system-level roles, not tenant-scoped.

### EBS CSI Driver

```typescript
// cdk/lib/eks-cluster-stack.ts — "EBS CSI Driver" section
const ebsCsiRole = new iam.Role(this, 'EbsCsiRole', {
  roleName: `EbsCsiDriverRole-${cluster.clusterName}`,
  assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonEBSCSIDriverPolicy'),
  ],
});
```

- Pod Identity association via `CfnAddon.podIdentityAssociations`
- Service account: `ebs-csi-controller-sa`

### CloudWatch Observability

```typescript
// cdk/lib/eks-cluster-stack.ts — "CloudWatch Container Insights" section
const cwObsRole = new iam.Role(this, 'CwObservabilityRole', {
  roleName: `CwObservabilityRole-${cluster.clusterName}`,
  assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
    iam.ManagedPolicy.fromAwsManagedPolicyName('AWSXrayWriteOnlyAccess'),
  ],
});
```

- Service account: `cloudwatch-agent`

### AWS Load Balancer Controller

```typescript
// cdk/lib/eks-cluster-stack.ts — "AWS Load Balancer Controller" section
const lbcSa = cluster.addServiceAccount('LbcSa', {
  name: 'aws-load-balancer-controller',
  namespace: 'kube-system',
});
```

- Uses IRSA (not Pod Identity) — created via `cluster.addServiceAccount`
- Broad permissions: EC2 describe/create SG, ELB full lifecycle, ACM, WAF, Cognito, Shield

### Karpenter Controller

```typescript
// cdk/lib/eks-cluster-stack.ts — "Karpenter" section
const karpenterSa = cluster.addServiceAccount('KarpenterSa', {
  name: 'karpenter',
  namespace: 'karpenter',
});
```

- Uses IRSA
- Permissions: EC2 fleet/instance management, IAM instance profiles, EKS describe, SQS (interruption queue), SSM, Pricing

### Karpenter Node Role

```typescript
const karpenterNodeRole = new iam.Role(this, 'KarpenterNodeRole', {
  roleName: `KarpenterNodeRole-${cluster.clusterName}`,
  assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
    iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
    iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
    iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
  ],
});
```

- EC2 instance role (not pod role) — assumed by Karpenter-launched nodes
- Mapped to `system:bootstrappers` + `system:nodes` in `awsAuth`

### EBS Snapshot

```typescript
// cdk/lib/eks-cluster-stack.ts — "IAM: EBS Snapshot" section
const snapshotRole = new iam.Role(this, 'EbsSnapshotRole', {
  roleName: `EbsSnapshotRole-${cluster.clusterName}`,
  assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
});
```

- Pod Identity role for PVC backup CronJobs
- Permissions: `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:DescribeSnapshots`, `ec2:DescribeVolumes`, `ec2:CreateTags`

## Tenant Isolation Summary

Isolation is enforced at three layers:

| Layer | Mechanism | What it prevents |
|-------|-----------|-----------------|
| **Kubernetes namespace** | Each tenant in its own namespace | Resource visibility isolation |
| **NetworkPolicy** | Egress blocks `10.0.0.0/8`, ingress same-NS only | Cross-tenant network traffic |
| **IAM ABAC** | `kubernetes-namespace` session tag in policy conditions | Cross-tenant AWS resource access |

All three layers must be breached for a tenant to access another tenant's data. No single layer is sufficient on its own — this is defense in depth.
