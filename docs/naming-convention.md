# Tenant Resource Naming Convention

The tenant name (e.g., `alice`) is the single input; all other names are derived.

## Convention Table

| Resource | Name Pattern | Example (`alice`) |
|----------|-------------|-------------------|
| ApplicationSet element | `{name}` | `alice` |
| Namespace | `openclaw-{name}` | `openclaw-alice` |
| ArgoCD Application | `tenant-{name}` (in `argocd` ns) | `tenant-alice` |
| ServiceAccount | `{name}` | `alice` |
| Deployment | `{name}` | `alice` |
| Service | `{name}` | `alice` |
| PVC | `{name}` | `alice` |
| ConfigMap | `{name}` | `alice` |
| Gateway token Secret | `{name}-gateway-token` | `alice-gateway-token` |
| NetworkPolicy | `{name}` | `alice` |
| ResourceQuota | `{name}` | `alice` |
| PDB | `{name}` | `alice` |
| HTTPRoute | `{name}` | `alice` |
| TargetGroupConfiguration | `{name}-tg` | `alice-tg` |
| KEDA HTTPScaledObject | `{name}` | `alice` |
| SM Secret | `openclaw/{name}/gateway-token` | `openclaw/alice/gateway-token` |
| Pod Identity Association | ns=`openclaw-{name}`, sa=`{name}` | ns=`openclaw-alice`, sa=`alice` |

## Rules

1. **Tenant name** is the ApplicationSet element `.metadata.name` -- lowercase alphanumeric + hyphens, max 63 chars
2. **Namespace** always prefixed with `openclaw-` to avoid collision with system namespaces
3. **All K8s resources within the namespace** use bare `{name}` (via Helm `fullnameOverride={name}`), except gateway-token Secret (`{name}-gateway-token`) and TGC (`{name}-tg`)
4. **ArgoCD Application** uses `tenant-{name}` in the `argocd` namespace
5. **Secrets Manager** uses path-style `openclaw/{name}/{secret-name}`
6. **Labels**: all resources carry `openclaw.io/tenant: {name}` and `app.kubernetes.io/managed-by: applicationset`

## Where Each Component Creates Resources

| Component | Creates |
|-----------|---------|
| PostConfirmation Lambda | SM Secret, Pod Identity Association, ApplicationSet element, K8s gateway-token Secret |
| Operator (5 ensure_* functions) | Namespace, PVC, ServiceAccount, ArgoCD Application, KEDA HSO |
| ArgoCD (syncs Helm chart) | Deployment, Service, ConfigMap, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TargetGroupConfiguration |
| create-tenant.sh (manual) | ApplicationSet element only (Operator + ArgoCD handle the rest) |
| provision-tenant.sh (recovery) | Pod Identity, SM Secret, Cognito attributes, ApplicationSet element, K8s gateway-token Secret |

## Validation

Tenant name is validated in three places (defense in depth):
1. ApplicationSet list generator (helm/applicationset.yaml)
2. Lambda PostConfirmation (cdk/lambda/post-confirmation/index.py)
3. PostConfirmation Lambda (`cdk/lambda/post-confirmation/index.py`)
