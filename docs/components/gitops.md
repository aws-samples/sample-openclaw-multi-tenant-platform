# GitOps — ArgoCD on EKS

## ArgoCD as EKS Capability

ArgoCD runs as a fully managed [EKS Capability](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html) — not a Helm chart. This means:

- No pods on worker nodes; runs in the EKS control plane
- Hosted UI with AWS Identity Center (SSO) authentication
- Automatic updates managed by AWS

### Architecture

```
EKS Capability (AWS-managed control plane)
  ├── ArgoCD Server (hosted UI, SSO auth)
  ├── ArgoCD Repo Server (Git sync)
  └── ArgoCD Application Controller (reconciliation)
        ├── Application: platform-keda
        ├── Application: platform-keda-http-addon
        └── ApplicationSet: openclaw-tenants
              ├── openclaw-alice (from helm/tenants/values-alice.yaml)
              ├── openclaw-bob
              └── ...
```

## Setup

### 1. Create IAM Capability Role

The role trusts `capabilities.eks.amazonaws.com` to assume it:

```bash
aws iam create-role --role-name EKSArgoCDCapabilityRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "capabilities.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'
```

### 2. Create ArgoCD Capability

```bash
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
```

### 3. Apply Applications and ApplicationSets

```bash
./scripts/setup-argocd.sh        # Check capability status
./scripts/setup-argocd-apps.sh   # Apply Applications + ApplicationSets
```

## Platform Components as Applications

Platform-level Helm charts are managed as ArgoCD Applications with automated sync and self-heal. Defined in `argocd/applications/platform.yaml`:

| Application | Chart | Source | Namespace |
|---|---|---|---|
| `platform-keda` | `keda` (v2.*) | `kedacore.github.io/charts` | `keda` |
| `platform-keda-http-addon` | `keda-add-ons-http` (v0.*) | `kedacore.github.io/charts` | `keda` |

Both use `syncPolicy.automated` with `prune: true` and `selfHeal: true`, plus `CreateNamespace=true`.

## Tenant ApplicationSet

The ApplicationSet in `argocd/applicationsets/tenants.yaml` uses a **Git file generator** to auto-discover tenants:

```yaml
generators:
  - git:
      repoURL: https://github.com/<YOUR_GITHUB_ORG>/openclaw-platform.git
      revision: main
      files:
        - path: helm/tenants/values-*.yaml
```

For each matching file, it creates an Application that:
- Uses `helm/charts/openclaw-platform` as the chart source
- References the tenant's values file via `helm.valueFiles`
- Deploys to namespace `openclaw-{{path.basenameNormalized}}`
- Auto-syncs with prune and self-heal enabled

## Tenant Lifecycle via GitOps

**Add a tenant:**

1. Create `helm/tenants/values-<name>.yaml` (via Tenant Operator)
2. `git push` to `main`
3. ArgoCD detects the new file → creates namespace + all resources

**Remove a tenant:**

1. Delete `helm/tenants/values-<name>.yaml`
2. `git push` to `main`
3. ArgoCD prunes all resources (`prune: true`)

## Files

| File | Purpose |
|---|---|
| `argocd/applications/platform.yaml` | KEDA + HTTP Add-on as ArgoCD Applications |
| `argocd/applicationsets/tenants.yaml` | Tenant ApplicationSet (Git file generator) |
| `scripts/setup-argocd.sh` | Check capability status |
| `scripts/setup-argocd-apps.sh` | Apply Applications + ApplicationSets |

## References

- [EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html)
- [Create Argo CD Capability](https://docs.aws.amazon.com/eks/latest/userguide/create-argocd-capability.html)
- [Capability IAM Role](https://docs.aws.amazon.com/eks/latest/userguide/capability-role.html)
