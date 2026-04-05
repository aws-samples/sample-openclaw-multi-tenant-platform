# GitOps -- ArgoCD on EKS

## Architecture

ArgoCD manages tenant resources. The ApplicationSet manages ArgoCD Application CRs, and ArgoCD syncs the Helm chart to create all tenant K8s resources.

```
Tenant Provisioning:
  Cognito SignUp -> PostConfirmation Lambda -> ApplicationSet element
    -> ApplicationSet generates Applications:
         ensure_namespace    -> Namespace
         ensure_argocd_app   -> ArgoCD Application (in argocd namespace)
    -> ArgoCD syncs Helm chart:
         Deployment, Service, ConfigMap, NetworkPolicy,
         ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration
```

### What ApplicationSet Creates

| Resource | Function |
|----------|----------|
| Namespace (`openclaw-{tenant}`) | ApplicationSet `managedNamespaceMetadata` + `CreateNamespace=true` |
| ArgoCD Application (`{tenant}` in `argocd` ns) | ApplicationSet List generator |

### What ArgoCD Syncs (Helm Chart)

| Resource | Helm Template |
|----------|---------------|
| Deployment | `deployment.yaml` |
| Service | `service.yaml` |
| ConfigMap | `configmap.yaml` |
| NetworkPolicy | `networkpolicy.yaml` |
| ResourceQuota | `resourcequota.yaml` |
| PDB | `pdb.yaml` |
| HTTPRoute | `httproute.yaml` |
| TargetGroupConfiguration | `targetgroupconfig.yaml` |

## ArgoCD Application

The ApplicationSet manages an ArgoCD Application per tenant via SSA:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-{name}          # e.g. tenant-alice
  namespace: argocd
  labels:
    openclaw.io/tenant: {name}
    app.kubernetes.io/managed-by: applicationset
spec:
  project: default
  source:
    repoURL: https://github.com/snese/sample-openclaw-multi-tenant-platform.git
    targetRevision: main
    path: helm/charts/openclaw-platform
    helm:
      values: |
        fullnameOverride: {name}
        tenant:
          name: {name}
          ...
  destination:
    name: in-cluster
    namespace: openclaw-{name}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true    # ApplicationSet creates the namespace
```

Key points:
- `fullnameOverride: {name}` -- all Helm resource names = tenant name
- `selfHeal: true` -- ArgoCD reverts manual changes (including direct `helm upgrade`)
- `CreateNamespace=true` -- ApplicationSet creates namespace with PSS labels

## ArgoCD as EKS Capability

ArgoCD runs as a fully managed [EKS Capability](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html):

- No pods on worker nodes; fully managed by AWS
- Hosted UI with AWS Identity Center (SSO) authentication
- Automatic updates managed by AWS

## References

- [Helm chart](../../helm/charts/openclaw-platform/) -- tenant resource templates
- [Naming Convention](../naming-convention.md)
