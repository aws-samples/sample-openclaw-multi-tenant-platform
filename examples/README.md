# Examples

## Add a Tenant

Add a tenant to the ApplicationSet (ArgoCD creates the workspace automatically):

```bash
./scripts/create-tenant.sh alice --email alice@example.com
```

Check status:

```bash
kubectl get applications -n argocd -l openclaw.io/tenant
```

## Remove a Tenant

```bash
./scripts/delete-tenant.sh alice
```

This removes the ApplicationSet element, ArgoCD Application, namespace (including PVC), Pod Identity association, and Secrets Manager secret.
