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

Remove a tenant element from the ApplicationSet. ArgoCD will prune the Application and all resources.

> **Note:** PVC data is retained by default (`Delete=false`). To fully clean up, also delete the namespace: `kubectl delete namespace openclaw-alice`
