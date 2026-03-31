# GitOps — ArgoCD on EKS

## Current Architecture

Tenant lifecycle is managed entirely by the **Tenant Operator** (Rust/kube-rs). The operator creates all K8s resources directly via server-side apply — no GitOps layer for tenant provisioning.

ArgoCD runs as a fully managed [EKS Capability](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html) for **platform components only** (KEDA, monitoring). It is not involved in tenant resource management.

```
Tenant Provisioning (no ArgoCD):
  Cognito SignUp → PostConfirmation Lambda → Tenant CR
    → Operator reconciles: Namespace, SA, PVC, Deployment, Service,
      ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TGC, KEDA HSO

Platform Components (ArgoCD optional):
  EKS Capability (AWS-managed control plane)
    └── ArgoCD Application Controller
          ├── Application: platform-keda
          └── Application: platform-keda-http-addon
```

## ArgoCD as EKS Capability

ArgoCD runs in the EKS control plane — not on worker nodes:

- No pods on worker nodes; fully managed by AWS
- Hosted UI with AWS Identity Center (SSO) authentication
- Automatic updates managed by AWS

### Setup

```bash
# 1. Create IAM Capability Role
aws iam create-role --role-name EKSArgoCDCapabilityRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "capabilities.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'

# 2. Create ArgoCD Capability
aws eks create-capability \
  --capability-name openclaw-argocd \
  --cluster-name openclaw-cluster \
  --type ARGOCD \
  --role-arn arn:aws:iam::<ACCOUNT>:role/EKSArgoCDCapabilityRole \
  --region us-west-2
```

## What ArgoCD Does NOT Manage

| Resource | Managed By |
|----------|-----------|
| Tenant namespaces, deployments, PVCs | Tenant Operator |
| HTTPRoute, NetworkPolicy, ResourceQuota | Tenant Operator |
| KEDA HTTPScaledObject | Tenant Operator |
| ServiceAccount, ConfigMap, Service | Tenant Operator |

## References

- [EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html)
- [Tenant Operator source](../../operator/src/resources.rs)
- [Naming Convention](../naming-convention.md)
