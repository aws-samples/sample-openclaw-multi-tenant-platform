use crate::types::{TENANT_FINALIZER, Tenant};
use crate::{Error, Metrics, Result, resources};
use futures::StreamExt;
use kube::{
    Resource, ResourceExt,
    api::{Api, ListParams, Patch, PatchParams},
    client::Client,
    runtime::{
        controller::{Action, Controller},
        events::{Event, EventType, Recorder, Reporter},
        finalizer::{Event as Finalizer, finalizer},
        watcher::Config,
    },
};
use serde::Serialize;
use serde_json::json;
use std::sync::Arc;
use tokio::{sync::RwLock, time::Duration};
use tracing::*;

// --- Reconciler Context ---

#[derive(Clone)]
pub struct Context {
    pub client: Client,
    pub recorder: Recorder,
    pub diagnostics: Arc<RwLock<Diagnostics>>,
    pub metrics: Arc<Metrics>,
}

// --- Reconcile Logic ---

#[instrument(skip(ctx, tenant), fields(trace_id))]
async fn reconcile(tenant: Arc<Tenant>, ctx: Arc<Context>) -> Result<Action> {
    let _timer = ctx.metrics.reconcile_count.clone();
    let name = tenant.name_any();

    // Server-side validation (defense in depth — webhook may be bypassed)
    if name.is_empty()
        || name.len() > 63
        || !name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        return Err(Error::ValidationError(format!(
            "Invalid tenant name: {name}"
        )));
    }

    let tenant_ns = format!("openclaw-{name}");

    info!("Reconciling Tenant \"{name}\"");

    let tenants: Api<Tenant> = Api::default_namespaced(ctx.client.clone());

    finalizer(&tenants, TENANT_FINALIZER, tenant, |event| async {
        match event {
            Finalizer::Apply(tenant) => apply(tenant, &tenant_ns, ctx.clone()).await,
            Finalizer::Cleanup(tenant) => cleanup(tenant, &tenant_ns, ctx.clone()).await,
        }
    })
    .await
    .map_err(|e| Error::FinalizerError(Box::new(e)))
}

/// Apply desired state: ensure namespace, PVC, ServiceAccount, K8s resources, KEDA HSO
async fn apply(tenant: Arc<Tenant>, tenant_ns: &str, ctx: Arc<Context>) -> Result<Action> {
    let client = ctx.client.clone();
    let name = tenant.name_any();
    let oref = tenant.object_ref(&());
    let ssapply = PatchParams::apply("tenant-operator").force();

    // Set phase to Provisioning at the start of reconciliation
    let tenants: Api<Tenant> = Api::default_namespaced(client.clone());
    let provisioning_status = json!({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "status": {
            "phase": "Provisioning",
            "conditions": []
        }
    });
    tenants
        .patch_status(&name, &ssapply, &Patch::Apply(provisioning_status))
        .await
        .map_err(Error::KubeError)?;

    // Ensure resources — collect conditions as we go
    let mut conditions = Vec::new();

    resources::ensure_namespace(client.clone(), &name, tenant_ns, &ssapply).await?;
    conditions.push(json!({ "type": "NamespaceReady", "status": "True" }));

    let pvc_condition = resources::ensure_pvc(client.clone(), &name, tenant_ns, &ssapply).await?;
    conditions.push(pvc_condition);

    resources::ensure_service_account(client.clone(), &name, tenant_ns, &ssapply).await?;

    let argocd_condition =
        resources::ensure_argocd_app(client.clone(), &name, tenant_ns, &ssapply, &tenant.spec)
            .await?;
    conditions.push(argocd_condition);

    let keda_condition = resources::ensure_keda_hso(
        client.clone(),
        &name,
        tenant_ns,
        &ssapply,
        tenant.spec.always_on,
    )
    .await?;
    conditions.push(keda_condition);

    // Check ArgoCD Application sync + health status
    let argocd_ready = check_argocd_sync(&client, &name).await;
    conditions.push(argocd_ready.clone());

    // Check actual Deployment availability
    let deploy_condition = check_deployment(&client, &name, tenant_ns).await;
    conditions.push(deploy_condition.clone());

    // Determine phase based on actual readiness
    let argocd_ok = argocd_ready.get("status").and_then(|v| v.as_str()) == Some("True");
    let deploy_ok = deploy_condition.get("status").and_then(|v| v.as_str()) == Some("True");

    let phase = if !tenant.spec.enabled {
        "Suspended"
    } else if argocd_ok && deploy_ok {
        "Ready"
    } else {
        "Provisioning"
    };

    // Update status with accurate phase
    let status = json!({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "status": {
            "phase": phase,
            "conditions": conditions
        }
    });
    tenants
        .patch_status(&name, &ssapply, &Patch::Apply(status))
        .await
        .map_err(Error::KubeError)?;

    // Publish event
    ctx.recorder
        .publish(
            &Event {
                type_: EventType::Normal,
                reason: "Reconciled".into(),
                note: Some(format!("Tenant {name} reconciled: phase={phase}")),
                action: "Reconciling".into(),
                secondary: None,
            },
            &oref,
        )
        .await
        .map_err(Error::KubeError)?;

    // If not fully ready yet, requeue sooner for faster convergence
    let requeue_secs = if phase == "Ready" { 300 } else { 30 };
    Ok(Action::requeue(Duration::from_secs(requeue_secs)))
}

/// Check ArgoCD Application sync and health status.
/// Reads ARGOCD_NAMESPACE env var (default: "argocd") for portability.
async fn check_argocd_sync(client: &Client, name: &str) -> serde_json::Value {
    use kube::api::{ApiResource, DynamicObject};

    let argocd_ns = std::env::var("ARGOCD_NAMESPACE").unwrap_or_else(|_| "argocd".into());

    let ar = ApiResource {
        group: "argoproj.io".into(),
        version: "v1alpha1".into(),
        kind: "Application".into(),
        api_version: "argoproj.io/v1alpha1".into(),
        plural: "applications".into(),
    };
    let app_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), &argocd_ns, &ar);
    let app_name = format!("tenant-{name}");

    match app_api.get(&app_name).await {
        Ok(app) => {
            let status = app.data.get("status");
            let sync_status = status
                .and_then(|s| s.get("sync"))
                .and_then(|s| s.get("status"))
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown");
            let health_status = status
                .and_then(|s| s.get("health"))
                .and_then(|s| s.get("status"))
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown");

            let ok = sync_status == "Synced" && health_status == "Healthy";
            json!({
                "type": "ArgoSyncHealthy",
                "status": if ok { "True" } else { "False" },
                "message": format!("sync={sync_status}, health={health_status}")
            })
        }
        Err(e) => {
            json!({
                "type": "ArgoSyncHealthy",
                "status": "False",
                "message": format!("Failed to get ArgoCD Application: {e}")
            })
        }
    }
}

/// Check if the tenant Deployment has available replicas
async fn check_deployment(client: &Client, name: &str, tenant_ns: &str) -> serde_json::Value {
    use k8s_openapi::api::apps::v1::Deployment;

    let deploy_api: Api<Deployment> = Api::namespaced(client.clone(), tenant_ns);
    match deploy_api.get(name).await {
        Ok(deploy) => {
            let available = deploy
                .status
                .as_ref()
                .and_then(|s| s.available_replicas)
                .unwrap_or(0);
            let (status, message) = if available >= 1 {
                ("True", "Deployment has available replicas".to_string())
            } else {
                (
                    "False",
                    "Deployment has no available replicas yet".to_string(),
                )
            };
            json!({ "type": "DeploymentAvailable", "status": status, "message": message })
        }
        Err(_) => {
            json!({
                "type": "DeploymentAvailable",
                "status": "False",
                "message": "Deployment not found (ArgoCD may not have synced yet)"
            })
        }
    }
}

/// Cleanup on tenant deletion
async fn cleanup(tenant: Arc<Tenant>, tenant_ns: &str, ctx: Arc<Context>) -> Result<Action> {
    let client = ctx.client.clone();
    let name = tenant.name_any();
    let oref = tenant.object_ref(&());

    info!("Cleaning up Tenant \"{name}\"");

    // Delete namespace (cascades all resources inside)
    // PVC retention is handled by StorageClass reclaimPolicy
    let ns_api: Api<k8s_openapi::api::core::v1::Namespace> = Api::all(client.clone());
    if ns_api
        .get_opt(tenant_ns)
        .await
        .map_err(Error::KubeError)?
        .is_some()
    {
        ns_api
            .delete(tenant_ns, &Default::default())
            .await
            .map_err(Error::KubeError)?;
        info!("Deleted namespace {tenant_ns}");
    }

    ctx.recorder
        .publish(
            &Event {
                type_: EventType::Normal,
                reason: "Deleted".into(),
                note: Some(format!("Tenant {name} cleaned up")),
                action: "Deleting".into(),
                secondary: None,
            },
            &oref,
        )
        .await
        .map_err(Error::KubeError)?;

    Ok(Action::await_change())
}

fn error_policy(tenant: Arc<Tenant>, error: &Error, _ctx: Arc<Context>) -> Action {
    let name = tenant.name_any();
    warn!("Reconcile failed for {}: {:?}", name, error);

    // Do NOT update status here. error_policy is a sync fn called on a tokio
    // runtime thread — block_on() would deadlock, and tokio::spawn() races with
    // the next reconcile. Instead, rely on apply() setting phase=Provisioning at
    // the start of each attempt. If reconcile keeps failing, status stays
    // Provisioning with stale/empty conditions, which is an accurate signal.
    // The error is visible via: kubectl describe tenant (events) + operator logs.

    Action::requeue(Duration::from_secs(60))
}

// --- Diagnostics & State ---

#[derive(Clone, Serialize)]
pub struct Diagnostics {
    #[serde(skip)]
    pub reporter: Reporter,
}

impl Default for Diagnostics {
    fn default() -> Self {
        Self {
            reporter: "tenant-operator".into(),
        }
    }
}

impl Diagnostics {
    fn recorder(&self, client: Client) -> Recorder {
        Recorder::new(client, self.reporter.clone())
    }
}

#[derive(Clone, Default)]
pub struct State {
    diagnostics: Arc<RwLock<Diagnostics>>,
    metrics: Arc<Metrics>,
}

impl State {
    pub fn metrics(&self) -> String {
        let mut buffer = String::new();
        let registry = &*self.metrics.registry;
        prometheus_client::encoding::text::encode(&mut buffer, registry)
            .unwrap_or_else(|e| tracing::error!("Failed to encode metrics: {:?}", e));
        buffer
    }

    pub async fn diagnostics(&self) -> Diagnostics {
        self.diagnostics.read().await.clone()
    }

    pub async fn to_context(&self, client: Client) -> Arc<Context> {
        Arc::new(Context {
            client: client.clone(),
            recorder: self.diagnostics.read().await.recorder(client),
            metrics: self.metrics.clone(),
            diagnostics: self.diagnostics.clone(),
        })
    }
}

/// Initialize and run the controller
pub async fn run(state: State) {
    let client = Client::try_default()
        .await
        .expect("Failed to create kube Client");
    let tenants = Api::<Tenant>::default_namespaced(client.clone());
    if let Err(e) = tenants.list(&ListParams::default().limit(1)).await {
        error!("CRD is not queryable; {e:?}. Is the CRD installed?");
        info!("Installation: cargo run --bin crdgen | kubectl apply -f -");
        std::process::exit(1);
    }
    Controller::new(tenants, Config::default().any_semantic())
        .shutdown_on_signal()
        .run(reconcile, error_policy, state.to_context(client).await)
        .filter_map(|x| async move { std::result::Result::ok(x) })
        .for_each(|_| futures::future::ready(()))
        .await;
}
