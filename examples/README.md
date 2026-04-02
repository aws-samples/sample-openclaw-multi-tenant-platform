# Examples

Sample manifests for manual testing and exploration.

## Tenant CR

Create a tenant without going through Cognito signup:

```bash
kubectl apply -f examples/tenant.yaml
```

Check status:

```bash
kubectl get tenant -n openclaw-system
kubectl get tenant example -n openclaw-system -o yaml
```

Expected status progression: `Provisioning` → `Ready`

Delete:

```bash
kubectl delete tenant example -n openclaw-system
```

> **Note:** The Operator creates the namespace and ArgoCD Application. Deleting the Tenant CR does not automatically clean up the namespace — see `docs/operations/admin-guide.md` for cleanup steps.
