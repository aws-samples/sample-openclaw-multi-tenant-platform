# Tenant Resource Naming Convention

All components (Operator, PostConfirmation Lambda, create-tenant.sh, Helm chart) MUST use these naming patterns. The tenant name (e.g., `alice`) is the single input; all other names are derived.

## Convention Table

| Resource | Name Pattern | Example (`alice`) |
|----------|-------------|-------------------|
| Tenant CR | `{tenant}` | `alice` |
| Namespace | `openclaw-{tenant}` | `openclaw-alice` |
| ServiceAccount | `{tenant}` | `alice` |
| Deployment | `{tenant}` | `alice` |
| Service | `{tenant}` | `alice` |
| PVC | `{tenant}` | `alice` |
| ConfigMap | `{tenant}` | `alice` |
| Gateway token Secret | `{tenant}-gateway-token` | `alice-gateway-token` |
| NetworkPolicy | `{tenant}` | `alice` |
| ResourceQuota | `{tenant}` | `alice` |
| PDB | `{tenant}` | `alice` |
| HTTPRoute | `{tenant}` | `alice` |
| TargetGroupConfiguration | `{tenant}` | `alice` |
| KEDA HTTPScaledObject | `{tenant}` | `alice` |
| SM Secret | `openclaw/{tenant}/gateway-token` | `openclaw/alice/gateway-token` |
| Pod Identity Association | ns=`openclaw-{tenant}`, sa=`{tenant}` | ns=`openclaw-alice`, sa=`alice` |
| Cognito attribute | `custom:gateway_token` | (per-user, not per-tenant) |

## Rules

1. **Tenant name** is the Tenant CR `.metadata.name` — lowercase alphanumeric + hyphens, max 63 chars
2. **Namespace** always prefixed with `openclaw-` to avoid collision with system namespaces
3. **All K8s resources within the namespace** use bare `{tenant}` as name (no prefix/suffix except gateway-token Secret)
4. **Secrets Manager** uses path-style `openclaw/{tenant}/{secret-name}`
5. **Labels**: all resources carry `openclaw.io/tenant: {tenant}` and `app.kubernetes.io/managed-by: tenant-operator`

## Where Each Component Creates Resources

| Component | Creates |
|-----------|---------|
| PostConfirmation Lambda | Pod Identity Association, SM Secret, Cognito attribute, Tenant CR, gateway-token K8s Secret |
| Operator | Namespace, SA, Deployment, Service, ConfigMap, PVC, NetworkPolicy, ResourceQuota, PDB, HTTPRoute, TGC, KEDA HSO |
| create-tenant.sh (manual) | Same as Lambda (for manual provisioning without Cognito) |

## Validation

Tenant name is validated in three places (defense in depth):
1. Webhook admission controller (`operator/src/webhook.rs`)
2. Operator reconciler (`operator/src/controller.rs`)
3. PostConfirmation Lambda (`cdk/lambda/post-confirmation/index.py`)
