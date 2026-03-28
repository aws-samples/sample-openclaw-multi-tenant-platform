# ArgoCD — EKS Managed Capability

## Overview

ArgoCD is deployed as an [EKS Capability](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html) — fully managed by AWS. This means:

- No Helm chart to maintain
- No pods running on your worker nodes
- Hosted UI with AWS Identity Center SSO authentication
- Automatic updates managed by AWS

## Prerequisites

- AWS Identity Center (SSO) configured in your organization
- IAM Capability Role with trust policy for `capabilities.eks.amazonaws.com`

## Setup

```bash
# 1. Create IAM Capability Role (one-time)
aws iam create-role --role-name EKSArgoCDCapabilityRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "capabilities.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'

# 2. Create ArgoCD capability
aws eks create-capability \
  --capability-name openclaw-argocd \
  --cluster-name openclaw-cluster \
  --type ARGOCD \
  --role-arn arn:aws:iam::<ACCOUNT>:role/EKSArgoCDCapabilityRole \
  --delete-propagation-policy RETAIN \
  --configuration '{
    "argoCd": {
      "namespace": "argocd",
      "awsIdc": {
        "idcInstanceArn": "<IDENTITY_CENTER_ARN>",
        "idcRegion": "<IDENTITY_CENTER_REGION>"
      },
      "rbacRoleMappings": [{
        "role": "ADMIN",
        "identities": [{"id": "<SSO_USER_ID>", "type": "SSO_USER"}]
      }]
    }
  }' \
  --region us-west-2

# 3. Check status
./scripts/setup-argocd.sh

# 4. Apply ApplicationSets
./scripts/setup-argocd-apps.sh
```

## Architecture

```
EKS Capability (AWS-managed, runs in control plane)
  │
  ├── ArgoCD Server (hosted UI, SSO auth)
  ├── ArgoCD Repo Server (Git sync)
  └── ArgoCD Application Controller (reconciliation)
        │
        ├── Application: platform-keda (KEDA Helm chart)
        ├── Application: platform-keda-http-addon
        └── ApplicationSet: openclaw-tenants
              ├── openclaw-alice (from helm/tenants/values-alice.yaml)
              ├── openclaw-bob
              └── openclaw-carol
```

## Tenant Management with ArgoCD

With ArgoCD ApplicationSet, adding a tenant is:

1. Create `helm/tenants/values-<name>.yaml` (via `create-tenant.sh`)
2. Git push
3. ArgoCD auto-syncs → creates namespace + all resources

Deleting a tenant:
1. Remove `helm/tenants/values-<name>.yaml`
2. Git push
3. ArgoCD prunes resources (if `prune: true`)

## Files

| File | Purpose |
|------|---------|
| `argocd/applications/platform.yaml` | KEDA as ArgoCD Application |
| `argocd/applicationsets/tenants.yaml` | Tenant ApplicationSet (Git file generator) |
| `scripts/setup-argocd.sh` | Check capability status |
| `scripts/setup-argocd-apps.sh` | Apply Applications + ApplicationSets |

## References

- [EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html)
- [Create Argo CD Capability](https://docs.aws.amazon.com/eks/latest/userguide/create-argocd-capability.html)
- [Capability IAM Role](https://docs.aws.amazon.com/eks/latest/userguide/capability-role.html)
