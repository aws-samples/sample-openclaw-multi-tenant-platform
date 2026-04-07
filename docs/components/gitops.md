# GitOps — ArgoCD + ApplicationSet

## Architecture

The platform uses a 3-layer model for tenant management:

```
Layer 1: ApplicationSet (ArgoCD)  → Generates per-tenant Applications from list elements
Layer 2: ArgoCD                   → GitOps: syncs Helm chart, drift detection, self-heal
Layer 3: Helm chart               → Workload: Deployment, Service, ConfigMap, NetworkPolicy, etc.
```

Tenant provisioning flow:

```
Cognito SignUp → PostConfirmation Lambda → ApplicationSet element
  → ApplicationSet generates per-tenant Application
  → ArgoCD syncs Helm chart → all tenant K8s resources created
```

### Why ApplicationSet + ArgoCD?

- **Reconcile loop**: if a resource is accidentally deleted, ArgoCD recreates it
- **Drift detection**: manual `kubectl` changes are reverted by `selfHeal: true`
- **Declarative state**: `kubectl get applications -n argocd -l openclaw.io/tenant` shows all tenants
- **GitOps**: changes via `git push`, not redeployment

## What Gets Created

| Resource | Created By | Helm Template |
|----------|-----------|---------------|
| Namespace (`openclaw-{tenant}`) | ApplicationSet (`CreateNamespace=true`) | — |
| ArgoCD Application | ApplicationSet List generator | — |
| Deployment | ArgoCD → Helm | `deployment.yaml` |
| Service | ArgoCD → Helm | `service.yaml` |
| ConfigMap | ArgoCD → Helm | `configmap.yaml` |
| NetworkPolicy | ArgoCD → Helm | `networkpolicy.yaml` |
| ResourceQuota | ArgoCD → Helm | `resourcequota.yaml` |
| PDB | ArgoCD → Helm | `pdb.yaml` |
| HTTPRoute | ArgoCD → Helm | `httproute.yaml` |
| TargetGroupConfiguration | ArgoCD → Helm | `targetgroupconfig.yaml` |
| HTTPScaledObject (KEDA) | ArgoCD → Helm | `httpscaledobject.yaml` |
| ReferenceGrant | ArgoCD → Helm | `referencegrant.yaml` |
| PVC (Amazon EFS) | ArgoCD → Helm | `pvc.yaml` |
| ServiceAccount | ArgoCD → Helm | `serviceaccount.yaml` |

## ArgoCD Application (per tenant)

The ApplicationSet generates one Application per tenant:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-{name}
  namespace: argocd
  labels:
    openclaw.io/tenant: {name}
spec:
  source:
    repoURL: https://github.com/{owner}/{repo}.git
    path: helm/charts/openclaw-platform
    helm:
      values: |
        fullnameOverride: {name}
        tenant:
          name: {name}
          email: {email}
  destination:
    name: in-cluster
    namespace: openclaw-{name}
  syncPolicy:
    automated:
      prune: true       # Delete resources removed from Helm chart
      selfHeal: true    # Revert manual changes
    syncOptions:
      - CreateNamespace=true
```

Key points:
- `fullnameOverride: {name}` — all Helm resource names = tenant name
- `selfHeal: true` — ArgoCD reverts manual changes
- `CreateNamespace=true` — namespace created with Pod Security Standards labels

## ArgoCD Setup

ArgoCD is installed via Helm (`scripts/setup-argocd.sh`). For production, consider migrating to [Amazon EKS ArgoCD Capability](https://docs.aws.amazon.com/eks/latest/userguide/argocd.html) (managed ArgoCD with Identity Center SSO).

## References

- [Helm chart](../../helm/charts/openclaw-platform/) — tenant resource templates
- [ApplicationSet manifest](../../helm/applicationset.yaml) — multi-tenant generator
- [Naming Convention](../naming-convention.md)
