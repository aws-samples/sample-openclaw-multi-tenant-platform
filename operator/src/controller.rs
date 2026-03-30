use crate::types::{TENANT_FINALIZER, Tenant, require_env};
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

    resources::ensure_namespace(client.clone(), &name, tenant_ns, &ssapply).await?;
    let pvc_condition = resources::ensure_pvc(client.clone(), &name, tenant_ns, &ssapply).await?;
    resources::ensure_service_account(client.clone(), &name, tenant_ns, &ssapply).await?;
    resources::ensure_config_map(client.clone(), &name, tenant_ns, &ssapply).await?;
    let deploy_condition =
        resources::ensure_deployment(client.clone(), &name, tenant_ns, &ssapply, &tenant.spec)
            .await?;
    resources::ensure_service(client.clone(), &name, tenant_ns, &ssapply).await?;
    resources::ensure_network_policy(client.clone(), &name, tenant_ns, &ssapply).await?;
    resources::ensure_resource_quota(client.clone(), &name, tenant_ns, &ssapply).await?;
    resources::ensure_pdb(client.clone(), &name, tenant_ns, &ssapply).await?;

    let cognito_pool_arn = require_env("COGNITO_POOL_ARN")?;
    let cognito_client_id = require_env("COGNITO_CLIENT_ID")?;
    let cognito_domain = require_env("COGNITO_DOMAIN")?;

    let httproute_condition = resources::ensure_httproute(
        client.clone(),
        &name,
        tenant_ns,
        &ssapply,
        &cognito_pool_arn,
    )
    .await?;
    let lrc_condition = resources::ensure_lrc(
        client.clone(),
        &name,
        tenant_ns,
        &ssapply,
        &cognito_pool_arn,
        &cognito_client_id,
        &cognito_domain,
    )
    .await?;
    let tgc_condition = resources::ensure_tgc(client.clone(), &name, tenant_ns, &ssapply).await?;
    let keda_condition =
        resources::ensure_keda_hso(client.clone(), &name, tenant_ns, &ssapply).await?;

    // Update status
    let status = json!({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "status": {
            "phase": if tenant.spec.enabled { "Ready" } else { "Suspended" },
            "conditions": [
                { "type": "NamespaceReady", "status": "True" },
                pvc_condition,
                deploy_condition,
                keda_condition,
                httproute_condition,
                lrc_condition,
                tgc_condition
            ]
        }
    });
    let tenants: Api<Tenant> = Api::default_namespaced(client.clone());
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
                note: Some(format!("Tenant {name} reconciled successfully")),
                action: "Reconciling".into(),
                secondary: None,
            },
            &oref,
        )
        .await
        .map_err(Error::KubeError)?;

    // Requeue every 5 minutes for drift detection
    Ok(Action::requeue(Duration::from_secs(300)))
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
    warn!("Reconcile failed for {}: {:?}", tenant.name_any(), error);
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
