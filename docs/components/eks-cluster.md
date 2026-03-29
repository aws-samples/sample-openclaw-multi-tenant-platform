# EKS Cluster

The OpenClaw platform runs on a single EKS cluster with Graviton-based managed nodes for system workloads and Karpenter for elastic tenant capacity.

All infrastructure is defined in `cdk/lib/eks-cluster-stack.ts`.

## Cluster Configuration

| Setting | Value |
|---------|-------|
| Cluster name | `openclaw-cluster` |
| Kubernetes version | 1.32 |
| Auth mode | `API_AND_CONFIG_MAP` |
| kubectl layer | `KubectlV32Layer` |
| Default capacity | 0 (all capacity via nodegroups/Karpenter) |

```typescript
// cdk/lib/eks-cluster-stack.ts — "EKS Cluster" section
const cluster = new eks.Cluster(this, 'Cluster', {
  vpc,
  version: eks.KubernetesVersion.V1_32,
  defaultCapacity: 0,
  clusterName: 'openclaw-cluster',
  authenticationMode: eks.AuthenticationMode.API_AND_CONFIG_MAP,
  kubectlLayer: new KubectlV32Layer(this, 'KubectlLayer'),
});
```

### Cluster Access

Deployer access is granted via SSO role, passed as CDK context:

```bash
cdk deploy -c ssoRoleArn=arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/MyRole
```

This creates a `CfnAccessEntry` with `AmazonEKSClusterAdminPolicy` at cluster scope.

## Managed Node Group: system-graviton

The always-on node group runs system workloads (CoreDNS, Karpenter controller, LB controller, CloudWatch agent).

| Setting | Value |
|---------|-------|
| Name | `system-graviton` |
| Instance type | `t4g.medium` (ARM64 Graviton) |
| AMI | AL2023 ARM64 Standard |
| Min / Desired / Max | 1 / 2 / 5 |
| Node label | `role=system` |

```typescript
// cdk/lib/eks-cluster-stack.ts — "Managed Node Group" section
cluster.addNodegroupCapacity('SystemNodes', {
  instanceTypes: [new ec2.InstanceType('t4g.medium')],
  amiType: eks.NodegroupAmiType.AL2023_ARM_64_STANDARD,
  minSize: 1, maxSize: 5, desiredSize: 2,
  nodegroupName: 'system-graviton',
  labels: { role: 'system' },
});
```

## Karpenter (v1.3.3)

Karpenter handles elastic scaling for tenant workloads. It provisions Spot instances to minimize cost.

### Setup

1. **Node IAM Role** (`KarpenterNodeRole-openclaw-cluster`) — mapped to `system:bootstrappers` and `system:nodes` via `awsAuth`
2. **Instance Profile** — `KarpenterNodeInstanceProfile-openclaw-cluster`
3. **Controller Service Account** — IRSA-based, in `karpenter` namespace
4. **Helm chart** — `oci://public.ecr.aws/karpenter/karpenter` v1.3.3

### EC2NodeClass

```yaml
# Applied via cluster.addManifest('KarpenterNodeClass')
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-openclaw-cluster
  subnetSelectorTerms:
    - tags:
        kubernetes.io/role/internal-elb: "1"
        kubernetes.io/cluster/openclaw-cluster: owned
  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/openclaw-cluster: owned
```

Key points:
- Uses AL2023 (same as managed nodegroup) for consistency
- Selects **private subnets** via the `internal-elb` tag
- Selects the cluster's own security groups via the `owned` tag

### NodePool

```yaml
# Applied via cluster.addManifest('KarpenterNodePool')
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [on-demand, spot]
        - key: kubernetes.io/arch
          operator: In
          values: [arm64]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: [c, m, r]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
  limits:
    cpu: "100"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
```

Key points:
- **ARM64 only** — matches the Graviton strategy
- **Spot + On-Demand** — Karpenter picks Spot first for cost savings
- **c/m/r categories, gen 3+** — compute, general-purpose, and memory-optimized families
- **100 vCPU limit** — hard cap on total Karpenter-managed capacity
- **Aggressive consolidation** — empty/underutilized nodes consolidated after 1 minute

## EKS Add-ons

### Installed via CfnAddon (CDK-managed)

| Add-on | IAM | Notes |
|--------|-----|-------|
| `aws-ebs-csi-driver` | Pod Identity → `EbsCsiDriverRole` | `AmazonEBSCSIDriverPolicy` managed policy |
| `eks-pod-identity-agent` | None | Enables Pod Identity for all pods |
| `vpc-cni` | None | Default config |
| `coredns` | None | Default config |
| `kube-proxy` | None | Default config |
| `amazon-cloudwatch-observability` | Pod Identity → `CwObservabilityRole` | `CloudWatchAgentServerPolicy` + `AWSXrayWriteOnlyAccess` |

### Installed via Helm (CDK-managed)

| Component | Chart | Namespace | IAM |
|-----------|-------|-----------|-----|
| AWS Load Balancer Controller | `aws-load-balancer-controller` (eks-charts) | `kube-system` | IRSA service account with EC2/ELB/ACM/WAF/Cognito permissions |
| Karpenter | `karpenter` v1.3.3 (public ECR) | `karpenter` | IRSA service account with EC2/IAM/EKS/SQS/SSM/Pricing permissions |

### gp3 StorageClass

CDK applies a `gp3` StorageClass as the default for tenant PVCs:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

## ArgoCD (EKS Capability)

ArgoCD is **not** deployed via Helm. It uses the EKS ArgoCD Capability — a fully managed ArgoCD instance provided by AWS.

```bash
aws eks create-capability --type ARGOCD --cluster-name openclaw-cluster
```

Benefits:
- Fully managed — no Helm chart to maintain
- Hosted UI with AWS Identity Center authentication
- See `scripts/setup-argocd.sh` and `docs/argocd.md` for setup details

## CloudWatch Alerts

A pod restart alarm monitors Container Insights metrics:

```typescript
// cdk/lib/eks-cluster-stack.ts — "CloudWatch Alerts" section
new cloudwatch.Alarm(this, 'PodRestartAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'ContainerInsights',
    metricName: 'pod_number_of_container_restarts',
    dimensionsMap: { ClusterName: 'openclaw-cluster' },
    period: cdk.Duration.seconds(300),
    statistic: 'Sum',
  }),
  threshold: 0,
  comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
});
```

Fires to the `OpenClawAlerts` SNS topic on any container restart.
