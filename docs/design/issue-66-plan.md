# Issue #66: Operator Takes Over 6 Resources

## Summary

Move HTTPRoute, NetworkPolicy, ListenerRuleCfg, TargetGroupCfg, ResourceQuota, PDB
from Helm/ArgoCD to direct operator server-side apply in `apply()`.
This eliminates the ArgoCD Application dependency for these resources.

## Resource Classification

| Resource | API Group | Kind | Type |
|----------|-----------|------|------|
| HTTPRoute | gateway.networking.k8s.io/v1 | HTTPRoute | DynamicObject (CRD) |
| NetworkPolicy | networking.k8s.io/v1 | NetworkPolicy | k8s-openapi native |
| ListenerRuleConfiguration | gateway.k8s.aws/v1beta1 | ListenerRuleConfiguration | DynamicObject (CRD) |
| TargetGroupConfiguration | gateway.k8s.aws/v1beta1 | TargetGroupConfiguration | DynamicObject (CRD) |
| ResourceQuota | v1 | ResourceQuota | k8s-openapi native |
| PodDisruptionBudget | policy/v1 | PodDisruptionBudget | k8s-openapi native |

## New Env Vars

None required — all values already available:
- `GATEWAY_DOMAIN` — already read (for HTTPRoute gateway ref)
- `COGNITO_POOL_ARN`, `COGNITO_CLIENT_ID`, `COGNITO_DOMAIN` — already read
- Tenant `name`, `tenant_ns`, `service.port=18789` — already in scope

## New Imports

```rust
use k8s_openapi::api::core::v1::ResourceQuota;
use k8s_openapi::api::networking::v1::NetworkPolicy;
use k8s_openapi::api::policy::v1::PodDisruptionBudget;
```

## Error Handling

Gateway CRDs (HTTPRoute, ListenerRuleCfg, TargetGroupCfg) may not be installed.
Use the same try/match pattern as ArgoCD Application and KEDA HSO:

```rust
let condition = match api.patch(&name, &ssapply, &Patch::Apply(patch)).await {
    Ok(_) => json!({ "type": "XxxReady", "status": "True" }),
    Err(e) => {
        warn!("Xxx failed: {e}");
        json!({ "type": "XxxReady", "status": "False", "message": e.to_string() })
    }
};
```

NetworkPolicy, ResourceQuota, PDB are core APIs — these should hard-fail (use `map_err(Error::KubeError)?`).

## Resource 1: NetworkPolicy (native, hard-fail)

```rust
// NetworkPolicy — restrict ingress/egress per tenant namespace
let np_api: Api<NetworkPolicy> = Api::namespaced(client.clone(), tenant_ns);
let np_patch: serde_json::Value = json!({
    "apiVersion": "networking.k8s.io/v1",
    "kind": "NetworkPolicy",
    "metadata": {
        "name": &name,
        "namespace": tenant_ns,
        "labels": {
            "openclaw.io/tenant": &name,
            "app.kubernetes.io/managed-by": "tenant-operator"
        }
    },
    "spec": {
        "podSelector": {},
        "policyTypes": ["Ingress", "Egress"],
        "ingress": [
            { "ports": [{ "protocol": "TCP", "port": 18789 }] },
            { "from": [{ "podSelector": {} }] }
        ],
        "egress": [
            { "to": [{ "namespaceSelector": {} }],
              "ports": [{ "protocol": "UDP", "port": 53 }, { "protocol": "TCP", "port": 53 }] },
            { "to": [{ "ipBlock": { "cidr": "169.254.170.23/32" } }],
              "ports": [{ "protocol": "TCP", "port": 80 }] },
            { "to": [{ "ipBlock": { "cidr": "169.254.169.254/32" } }],
              "ports": [{ "protocol": "TCP", "port": 80 }] },
            { "to": [{ "ipBlock": { "cidr": "0.0.0.0/0", "except": ["10.0.0.0/8"] } }],
              "ports": [{ "protocol": "TCP", "port": 443 }] },
            { "to": [{ "podSelector": {} }] }
        ]
    }
});
np_api.patch(&name, &ssapply, &Patch::Apply(np_patch)).await.map_err(Error::KubeError)?;
info!("Ensured NetworkPolicy {name} in {tenant_ns}");
```

## Resource 2: ResourceQuota (native, hard-fail)

```rust
// ResourceQuota — cap CPU/memory/pods per tenant namespace
let rq_api: Api<ResourceQuota> = Api::namespaced(client.clone(), tenant_ns);
let rq_patch: serde_json::Value = json!({
    "apiVersion": "v1",
    "kind": "ResourceQuota",
    "metadata": {
        "name": &name,
        "namespace": tenant_ns,
        "labels": {
            "openclaw.io/tenant": &name,
            "app.kubernetes.io/managed-by": "tenant-operator"
        }
    },
    "spec": {
        "hard": {
            "limits.cpu": "4",
            "limits.memory": "8Gi",
            "pods": "10"
        }
    }
});
rq_api.patch(&name, &ssapply, &Patch::Apply(rq_patch)).await.map_err(Error::KubeError)?;
info!("Ensured ResourceQuota {name} in {tenant_ns}");
```

Note: Consider making cpu/memory/pods configurable via TenantSpec in a follow-up.

## Resource 3: PodDisruptionBudget (native, hard-fail)

```rust
// PDB — ensure minAvailable=1 during voluntary disruptions
let pdb_api: Api<PodDisruptionBudget> = Api::namespaced(client.clone(), tenant_ns);
let pdb_patch: serde_json::Value = json!({
    "apiVersion": "policy/v1",
    "kind": "PodDisruptionBudget",
    "metadata": {
        "name": &name,
        "namespace": tenant_ns,
        "labels": {
            "openclaw.io/tenant": &name,
            "app.kubernetes.io/managed-by": "tenant-operator"
        }
    },
    "spec": {
        "minAvailable": 1,
        "selector": {
            "matchLabels": {
                "app.kubernetes.io/name": "openclaw-platform",
                "app.kubernetes.io/instance": &name
            }
        }
    }
});
pdb_api.patch(&name, &ssapply, &Patch::Apply(pdb_patch)).await.map_err(Error::KubeError)?;
info!("Ensured PDB {name} in {tenant_ns}");
```

## Resource 4: HTTPRoute (DynamicObject, graceful fail)

```rust
let httproute_ar = ApiResource::from_gvk_with_plural(
    &kube::api::GroupVersionKind::gvk("gateway.networking.k8s.io", "v1", "HTTPRoute"),
    "httproutes",
);
let httproute_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), tenant_ns, &httproute_ar);

let mut httproute_rules = vec![json!({
    "matches": [{ "path": { "type": "PathPrefix", "value": format!("/t/{name}") } }],
    "backendRefs": [{ "name": &name, "port": 18789 }]
})];
// Inject Cognito filter if configured
if !cognito_pool_arn.is_empty() {
    httproute_rules[0]["filters"] = json!([{
        "type": "ExtensionRef",
        "extensionRef": {
            "group": "gateway.k8s.aws",
            "kind": "ListenerRuleConfiguration",
            "name": format!("{name}-cognito")
        }
    }]);
}

let httproute_patch: serde_json::Value = json!({
    "apiVersion": "gateway.networking.k8s.io/v1",
    "kind": "HTTPRoute",
    "metadata": {
        "name": &name,
        "namespace": tenant_ns,
        "labels": {
            "openclaw.io/tenant": &name,
            "app.kubernetes.io/managed-by": "tenant-operator"
        }
    },
    "spec": {
        "parentRefs": [{
            "group": "gateway.networking.k8s.io",
            "kind": "Gateway",
            "name": "openclaw-gateway",
            "namespace": "openclaw-system",
            "sectionName": "https"
        }],
        "rules": httproute_rules
    }
});
let httproute_condition = match httproute_api
    .patch(&name, &ssapply, &Patch::Apply(httproute_patch)).await
{
    Ok(_) => {
        info!("Ensured HTTPRoute {name} in {tenant_ns}");
        json!({ "type": "HTTPRouteReady", "status": "True" })
    }
    Err(e) => {
        warn!("HTTPRoute {name} failed: {e}");
        json!({ "type": "HTTPRouteReady", "status": "False", "message": e.to_string() })
    }
};
```

## Resource 5: ListenerRuleConfiguration (DynamicObject, graceful fail)

Only created when Cognito is configured.

```rust
let lrc_ar = ApiResource::from_gvk_with_plural(
    &kube::api::GroupVersionKind::gvk("gateway.k8s.aws", "v1beta1", "ListenerRuleConfiguration"),
    "listenerruleconfigurations",
);
let lrc_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), tenant_ns, &lrc_ar);
let lrc_name = format!("{name}-cognito");

let lrc_condition = if !cognito_pool_arn.is_empty() {
    let lrc_patch: serde_json::Value = json!({
        "apiVersion": "gateway.k8s.aws/v1beta1",
        "kind": "ListenerRuleConfiguration",
        "metadata": {
            "name": &lrc_name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": &name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "actions": [{
                "type": "authenticate-cognito",
                "authenticateCognitoConfig": {
                    "userPoolArn": &cognito_pool_arn,
                    "userPoolClientId": &cognito_client_id,
                    "userPoolDomain": &cognito_domain,
                    "onUnauthenticatedRequest": "authenticate",
                    "scope": "openid email profile",
                    "sessionTimeout": 604800
                }
            }]
        }
    });
    match lrc_api.patch(&lrc_name, &ssapply, &Patch::Apply(lrc_patch)).await {
        Ok(_) => {
            info!("Ensured ListenerRuleConfiguration {lrc_name} in {tenant_ns}");
            json!({ "type": "CognitoAuthReady", "status": "True" })
        }
        Err(e) => {
            warn!("ListenerRuleConfiguration {lrc_name} failed: {e}");
            json!({ "type": "CognitoAuthReady", "status": "False", "message": e.to_string() })
        }
    }
} else {
    json!({ "type": "CognitoAuthReady", "status": "True", "message": "Cognito not configured, skipped" })
};
```

## Resource 6: TargetGroupConfiguration (DynamicObject, graceful fail)

```rust
let tgc_ar = ApiResource::from_gvk_with_plural(
    &kube::api::GroupVersionKind::gvk("gateway.k8s.aws", "v1beta1", "TargetGroupConfiguration"),
    "targetgroupconfigurations",
);
let tgc_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), tenant_ns, &tgc_ar);
let tgc_name = format!("{name}-tg");

let tgc_patch: serde_json::Value = json!({
    "apiVersion": "gateway.k8s.aws/v1beta1",
    "kind": "TargetGroupConfiguration",
    "metadata": {
        "name": &tgc_name,
        "namespace": tenant_ns,
        "labels": {
            "openclaw.io/tenant": &name,
            "app.kubernetes.io/managed-by": "tenant-operator"
        }
    },
    "spec": {
        "targetReference": { "name": &name },
        "defaultConfiguration": {
            "targetType": "ip",
            "healthCheckConfig": {
                "healthCheckPath": "/healthz",
                "healthyThresholdCount": 2,
                "unhealthyThresholdCount": 2,
                "healthCheckIntervalSeconds": 15
            }
        }
    }
});
let tgc_condition = match tgc_api
    .patch(&tgc_name, &ssapply, &Patch::Apply(tgc_patch)).await
{
    Ok(_) => {
        info!("Ensured TargetGroupConfiguration {tgc_name} in {tenant_ns}");
        json!({ "type": "TargetGroupReady", "status": "True" })
    }
    Err(e) => {
        warn!("TargetGroupConfiguration {tgc_name} failed: {e}");
        json!({ "type": "TargetGroupReady", "status": "False", "message": e.to_string() })
    }
};
```

## Status Conditions Update

Add 4 new conditions to the existing status patch:

```rust
"conditions": [
    // existing
    { "type": "NamespaceReady", "status": "True" },
    { "type": "PVCBound", "status": "Unknown", "message": "Pending verification" },
    argocd_condition,
    keda_condition,
    // new — issue #66
    httproute_condition,
    lrc_condition,      // CognitoAuthReady
    tgc_condition,      // TargetGroupReady
    // NetworkPolicy, ResourceQuota, PDB are hard-fail so no condition needed
    // (if they fail, reconcile errors out before reaching status update)
]
```

## Insertion Order in apply()

Insert after step 3 (ServiceAccount), before step 5 (ArgoCD Application):

1. NetworkPolicy (hard-fail)
2. ResourceQuota (hard-fail)
3. PDB (hard-fail)
4. HTTPRoute (graceful) — needs `cognito_pool_arn` so must be after env var reads
5. ListenerRuleConfiguration (graceful, conditional on Cognito)
6. TargetGroupConfiguration (graceful)

Alternatively, place all 6 after the existing env var reads (after line where `cognito_domain` is read)
so all gateway-related resources are grouped together.

## Cleanup Considerations

No changes needed to `cleanup()` — deleting the namespace cascades all namespaced resources.
HTTPRoute, NetworkPolicy, LRC, TGC, ResourceQuota, PDB are all namespaced.

## Helm Template Removal (follow-up)

After operator takes over, remove these Helm templates (or gate them behind `operator.enabled: false`):
- `templates/httproute.yaml`
- `templates/networkpolicy.yaml`
- `templates/listenerruleconfig.yaml`
- `templates/targetgroupconfig.yaml`
- `templates/resourcequota.yaml`
- `templates/pdb.yaml`
