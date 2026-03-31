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

pub async fn ensure_argocd_app(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
    spec: &TenantSpec,
) -> Result<Value> {
    let repo_url = std::env::var("HELM_REPO_URL").unwrap_or_else(|_| {
        "https://github.com/snese/sample-openclaw-multi-tenant-platform.git".into()
    });
    let target_revision = std::env::var("HELM_TARGET_REVISION").unwrap_or_else(|_| "main".into());
    let gateway_domain = std::env::var("GATEWAY_DOMAIN").unwrap_or_default();
    let cognito_client_id = std::env::var("COGNITO_CLIENT_ID").unwrap_or_default();
    let cognito_domain = std::env::var("COGNITO_DOMAIN").unwrap_or_default();
    let cognito_pool_arn = std::env::var("COGNITO_POOL_ARN").unwrap_or_default();

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
