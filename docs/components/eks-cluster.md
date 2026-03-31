# EKS Cluster

Single EKS cluster with Graviton-based managed nodes for system workloads and Karpenter for elastic tenant capacity.

All infrastructure defined in `cdk/lib/eks-cluster-stack.ts`.

## Cluster Configuration

| Setting | Value |
|---------|-------|
| Cluster name | `openclaw-cluster` |
| Kubernetes version | 1.32 |
| Auth mode | `API_AND_CONFIG_MAP` |
| Default capacity | 0 (all capacity via nodegroups/Karpenter) |

## Managed Node Group: system-graviton

Always-on node group for system workloads (CoreDNS, Karpenter, LB controller, CloudWatch agent).

| Setting | Value |
|---------|-------|
| Instance type | `t4g.medium` (ARM64 Graviton) |
| AMI | AL2023 ARM64 Standard |
| Min / Desired / Max | 1 / 2 / 5 |
| Node label | `role=system` |

## Karpenter (v1.3.3)

Elastic scaling for tenant workloads. Provisions Spot instances to minimize cost.

- **ARM64 only** -- matches the Graviton strategy
- **Spot + On-Demand** -- Karpenter picks Spot first
- **c/m/r categories, gen 3+** -- compute, general-purpose, memory-optimized
- **100 vCPU limit** -- hard cap on Karpenter-managed capacity
- **Aggressive consolidation** -- empty/underutilized nodes consolidated after 1 minute
- EC2NodeClass selects **private subnets** via `internal-elb` + cluster-owned tags

## EKS Add-ons

### CDK-managed (CfnAddon)

| Add-on | IAM | Notes |
|--------|-----|-------|
| `aws-ebs-csi-driver` | Pod Identity -> `EbsCsiDriverRole` | `AmazonEBSCSIDriverPolicy` |
| `eks-pod-identity-agent` | None | Enables Pod Identity |
| `vpc-cni` | None | Default config |
| `coredns` | None | Default config |
| `kube-proxy` | None | Default config |
| `amazon-cloudwatch-observability` | Pod Identity -> `CwObservabilityRole` | Container Insights |

### CDK-managed (Helm)

| Component | Namespace | IAM |
|-----------|-----------|-----|
| AWS Load Balancer Controller | `kube-system` | IRSA |
| Karpenter | `karpenter` | IRSA |

## Gateway API Resources

The platform uses Gateway API (not Ingress) for tenant traffic routing. Resources defined in `helm/gateway.yaml`:

| Resource | Purpose |
|----------|---------|
| GatewayClass (`openclaw-alb`) | Registers `gateway.k8s.aws/alb` controller |
| LoadBalancerConfiguration | Internet-facing ALB + CF prefix list SG (`pl-82a045eb`) |
| Gateway (`openclaw-gateway`) | HTTPS listener on `claw.{domain}`, allows routes from all namespaces |

Per-tenant HTTPRoute and TargetGroupConfiguration are created by the Helm chart (synced by ArgoCD).

## gp3 StorageClass

Default StorageClass for tenant PVCs:

```yaml
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

## ArgoCD (EKS Capability)

ArgoCD runs as a fully managed EKS Capability -- not deployed via Helm. Manages tenant resources via Application CRs created by the Operator.

## CloudWatch Alerts

Pod restart alarm monitors Container Insights metrics. Fires to `OpenClawAlerts` SNS topic on any container restart.
