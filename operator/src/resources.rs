use crate::types::TenantSpec;
use crate::{Error, Result};
use k8s_openapi::api::core::v1::Namespace;
use kube::{
    api::{Api, ApiResource, DynamicObject, ObjectMeta, Patch, PatchParams},
    client::Client,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use tracing::*;

pub async fn ensure_namespace(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let ns_api: Api<Namespace> = Api::all(client);
    let ns = Namespace {
        metadata: ObjectMeta {
            name: Some(tenant_ns.to_string()),
            labels: Some(BTreeMap::from([
                ("openclaw.io/tenant".to_string(), name.to_string()),
                (
                    "app.kubernetes.io/managed-by".to_string(),
                    "tenant-operator".to_string(),
                ),
                (
                    "pod-security.kubernetes.io/enforce".to_string(),
                    "restricted".to_string(),
                ),
                (
                    "pod-security.kubernetes.io/warn".to_string(),
                    "restricted".to_string(),
                ),
                (
                    "pod-security.kubernetes.io/audit".to_string(),
                    "restricted".to_string(),
                ),
            ])),
            annotations: Some(BTreeMap::from([
                (
                    "instrumentation.opentelemetry.io/inject-java".to_string(),
                    "false".to_string(),
                ),
                (
                    "instrumentation.opentelemetry.io/inject-nodejs".to_string(),
                    "false".to_string(),
                ),
                (
                    "instrumentation.opentelemetry.io/inject-python".to_string(),
                    "false".to_string(),
                ),
                (
                    "instrumentation.opentelemetry.io/inject-dotnet".to_string(),
                    "false".to_string(),
                ),
            ])),
            ..Default::default()
        },
        ..Default::default()
    };
    ns_api
        .patch(tenant_ns, ssapply, &Patch::Apply(ns))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured namespace {tenant_ns}");
    Ok(())
}

/// Read env var, treating CDK placeholder values as unset.
pub fn env_or_default(key: &str, default: &str) -> String {
    const KNOWN_PLACEHOLDERS: &[&str] = &[
        "REGION",
        "DOMAIN",
        "COGNITO_POOL_ARN",
        "COGNITO_CLIENT_ID",
        "COGNITO_DOMAIN",
        "GATEWAY_DOMAIN",
    ];
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .filter(|v| !KNOWN_PLACEHOLDERS.contains(&v.as_str()))
        .unwrap_or_else(|| default.into())
}

pub async fn ensure_argocd_app(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
    spec: &TenantSpec,
) -> Result<Value> {
    let repo_url = std::env::var("HELM_REPO_URL")
        .ok()
        .filter(|v| v != "https://github.com/ORG/REPO.git")
        .unwrap_or_else(|| {
            "https://github.com/snese/sample-openclaw-multi-tenant-platform.git".into()
        });
    let target_revision = std::env::var("HELM_TARGET_REVISION").unwrap_or_else(|_| "main".into());
    let gateway_domain = env_or_default("GATEWAY_DOMAIN", "");
    let cognito_client_id = env_or_default("COGNITO_CLIENT_ID", "");
    let cognito_domain = env_or_default("COGNITO_DOMAIN", "");
    let cognito_pool_arn = env_or_default("COGNITO_POOL_ARN", "");

    let budget = spec.budget.as_ref().map(|b| b.monthly_usd).unwrap_or(100);

    let helm_values = serde_yaml::to_string(&json!({
        "fullnameOverride": name,
        "tenant": {
            "name": name,
            "email": &spec.email,
            "enabled": spec.enabled,
            "budget": budget
        },
        "skills": &spec.skills,
        "scaleToZero": {
            "enabled": !spec.always_on && !gateway_domain.is_empty(),
            "minReplicas": if spec.always_on { 1 } else { 0 }
        },
        "ingress": {
            "host": &gateway_domain
        },
        "gateway": {
            "enabled": !gateway_domain.is_empty(),
            "domain": &gateway_domain,
            "gatewayName": "openclaw-gateway",
            "gatewayNamespace": "openclaw-system",
            "cognito": {
                "enabled": !cognito_client_id.is_empty(),
                "clientId": &cognito_client_id,
                "domain": &cognito_domain,
                "userPoolArn": &cognito_pool_arn
            }
        }
    }))
    .map_err(|e| Error::HelmError(e.to_string()))?;

    let ar = ApiResource {
        group: "argoproj.io".into(),
        version: "v1alpha1".into(),
        kind: "Application".into(),
        api_version: "argoproj.io/v1alpha1".into(),
        plural: "applications".into(),
    };
    let app_api: Api<DynamicObject> = Api::namespaced_with(client, "argocd", &ar);

    let app_name = format!("tenant-{name}");
    let app_patch: Value = json!({
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "metadata": {
            "name": &app_name,
            "namespace": "argocd",
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "project": "default",
            "source": {
                "repoURL": &repo_url,
                "targetRevision": &target_revision,
                "path": "helm/charts/openclaw-platform",
                "helm": {
                    "values": &helm_values
                }
            },
            "destination": {
                "name": "in-cluster",
                "namespace": tenant_ns
            },
            "ignoreDifferences": [{
                "group": "apps",
                "kind": "Deployment",
                "jsonPointers": ["/spec/replicas"]
            }, {
                "group": "gateway.k8s.aws",
                "kind": "TargetGroupConfiguration",
                "jsonPointers": ["/spec/defaultConfiguration/healthCheckConfig/healthCheckInterval"]
            }],
            "syncPolicy": {
                "automated": {
                    "prune": true,
                    "selfHeal": true
                },
                "syncOptions": ["CreateNamespace=false"]
            }
        }
    });
    app_api
        .patch(&app_name, ssapply, &Patch::Apply(app_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ArgoCD Application {app_name}");
    Ok(
        json!({ "type": "ArgoAppReady", "status": "True", "message": format!("ArgoCD Application {app_name} synced") }),
    )
}

/// Create a ReferenceGrant in the keda namespace allowing this tenant's
/// HTTPRoute to reference the KEDA interceptor Service (cross-namespace backendRef).
pub async fn ensure_reference_grant(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    // Ensure shared interceptor TGC exists (idempotent, created once for all tenants)
    ensure_interceptor_tgc(client.clone(), ssapply).await?;

    let ar = ApiResource {
        group: "gateway.networking.k8s.io".into(),
        version: "v1beta1".into(),
        kind: "ReferenceGrant".into(),
        api_version: "gateway.networking.k8s.io/v1beta1".into(),
        plural: "referencegrants".into(),
    };
    let rg_api: Api<DynamicObject> = Api::namespaced_with(client, "keda", &ar);
    let rg_name = format!("allow-{name}");
    let rg_patch: Value = json!({
        "apiVersion": "gateway.networking.k8s.io/v1beta1",
        "kind": "ReferenceGrant",
        "metadata": {
            "name": &rg_name,
            "namespace": "keda",
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "from": [{
                "group": "gateway.networking.k8s.io",
                "kind": "HTTPRoute",
                "namespace": tenant_ns
            }],
            "to": [{
                "group": "",
                "kind": "Service",
                "name": "keda-add-ons-http-interceptor-proxy"
            }]
        }
    });
    rg_api
        .patch(&rg_name, ssapply, &Patch::Apply(rg_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ReferenceGrant {rg_name} in keda namespace");
    Ok(())
}

/// Ensure a shared TargetGroupConfiguration exists for the KEDA interceptor
/// in the keda namespace. Without this, ALB controller defaults to Instance
/// target type for the interceptor Service (ClusterIP), which fails with
/// "TargetGroup port is empty".
async fn ensure_interceptor_tgc(client: Client, ssapply: &PatchParams) -> Result<()> {
    let ar = ApiResource {
        group: "gateway.k8s.aws".into(),
        version: "v1beta1".into(),
        kind: "TargetGroupConfiguration".into(),
        api_version: "gateway.k8s.aws/v1beta1".into(),
        plural: "targetgroupconfigurations".into(),
    };
    let tgc_api: Api<DynamicObject> = Api::namespaced_with(client, "keda", &ar);
    let tgc_patch: Value = json!({
        "apiVersion": "gateway.k8s.aws/v1beta1",
        "kind": "TargetGroupConfiguration",
        "metadata": {
            "name": "keda-interceptor-tg",
            "namespace": "keda",
            "labels": {
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "targetReference": {
                "name": "keda-add-ons-http-interceptor-proxy"
            },
            "defaultConfiguration": {
                "targetType": "ip",
                "healthCheckConfig": {
                    "healthCheckPath": "/readyz",
                    "healthCheckPort": "9090",
                    "healthyThresholdCount": 2,
                    "unhealthyThresholdCount": 2,
                    "healthCheckInterval": 15
                }
            }
        }
    });
    tgc_api
        .patch("keda-interceptor-tg", ssapply, &Patch::Apply(tgc_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured interceptor TGC in keda namespace");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Each test uses a unique env var name to avoid race conditions in parallel execution.

    #[test]
    fn env_or_default_returns_real_value() {
        unsafe { std::env::set_var("TEST_EODR_REAL", "claw.snese.net") };
        assert_eq!(
            env_or_default("TEST_EODR_REAL", "fallback"),
            "claw.snese.net"
        );
        unsafe { std::env::remove_var("TEST_EODR_REAL") };
    }

    #[test]
    fn env_or_default_filters_placeholder() {
        unsafe { std::env::set_var("TEST_EODR_PH", "DOMAIN") };
        assert_eq!(env_or_default("TEST_EODR_PH", "fallback"), "fallback");
        unsafe { std::env::remove_var("TEST_EODR_PH") };
    }

    #[test]
    fn env_or_default_filters_all_known_placeholders() {
        for (i, ph) in [
            "REGION",
            "DOMAIN",
            "COGNITO_POOL_ARN",
            "COGNITO_CLIENT_ID",
            "COGNITO_DOMAIN",
            "GATEWAY_DOMAIN",
        ]
        .iter()
        .enumerate()
        {
            let key = format!("TEST_EODR_KP_{i}");
            unsafe { std::env::set_var(&key, ph) };
            assert_eq!(
                env_or_default(&key, "fb"),
                "fb",
                "Failed for placeholder: {ph}"
            );
            unsafe { std::env::remove_var(&key) };
        }
    }

    #[test]
    fn env_or_default_allows_uppercase_real_values() {
        unsafe { std::env::set_var("TEST_EODR_UP", "US_EAST_1") };
        assert_eq!(env_or_default("TEST_EODR_UP", "fb"), "US_EAST_1");
        unsafe { std::env::remove_var("TEST_EODR_UP") };
    }

    #[test]
    fn env_or_default_empty_returns_default() {
        unsafe { std::env::set_var("TEST_EODR_EMPTY", "") };
        assert_eq!(env_or_default("TEST_EODR_EMPTY", "fb"), "fb");
        unsafe { std::env::remove_var("TEST_EODR_EMPTY") };
    }

    #[test]
    fn env_or_default_unset_returns_default() {
        unsafe { std::env::remove_var("TEST_EODR_UNSET") };
        assert_eq!(env_or_default("TEST_EODR_UNSET", "fb"), "fb");
    }
}
