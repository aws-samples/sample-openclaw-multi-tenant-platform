use crate::{Error, Metrics, Result};
use futures::StreamExt;
use k8s_openapi::api::core::v1::{ConfigMap, Namespace, PersistentVolumeClaim, ServiceAccount};
use k8s_openapi::api::networking::v1::NetworkPolicy;

use kube::{
    CustomResource, Resource, ResourceExt,
    api::{Api, ApiResource, DynamicObject, ListParams, ObjectMeta, Patch, PatchParams},
    client::Client,
    runtime::{
        controller::{Action, Controller},
        events::{Event, EventType, Recorder, Reporter},
        finalizer::{Event as Finalizer, finalizer},
        watcher::Config,
    },
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::{sync::RwLock, time::Duration};
use tracing::*;

pub static TENANT_FINALIZER: &str = "tenants.openclaw.io";

/// Tenant CRD spec — the desired state for one OpenClaw tenant
#[derive(CustomResource, Deserialize, Serialize, Clone, Debug, JsonSchema)]
#[cfg_attr(test, derive(Default))]
#[kube(
    kind = "Tenant",
    group = "openclaw.io",
    version = "v1alpha1",
    namespaced,
    status = "TenantStatus",
    shortname = "tn",
    printcolumn = r#"{"name":"Phase","type":"string","jsonPath":".status.phase"}"#,
    printcolumn = r#"{"name":"Email","type":"string","jsonPath":".spec.email"}"#,
    printcolumn = r#"{"name":"Budget","type":"integer","jsonPath":".spec.budget.monthlyUSD"}"#
)]
pub struct TenantSpec {
    /// Tenant email, must be unique across the cluster
    pub email: String,
    /// Human-readable display name
    #[serde(rename = "displayName")]
    pub display_name: String,
    /// Emoji identifier for dashboards and logs
    #[serde(default)]
    pub emoji: Option<String>,
    /// List of enabled skill names
    #[serde(default)]
    pub skills: Vec<String>,
    /// Budget configuration
    #[serde(default)]
    pub budget: Option<TenantBudget>,
    /// Whether the tenant is active. False suspends the tenant.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

#[derive(Deserialize, Serialize, Clone, Debug, Default, JsonSchema)]
pub struct TenantBudget {
    /// Monthly spend cap in USD
    #[serde(rename = "monthlyUSD", default = "default_budget")]
    pub monthly_usd: i64,
}

fn default_budget() -> i64 {
    100
}

/// Status subresource for Tenant
#[derive(Deserialize, Serialize, Clone, Default, Debug, JsonSchema)]
pub struct TenantStatus {
    /// Current phase: Pending, Provisioning, Ready, Suspended, Error
    #[serde(default)]
    pub phase: String,
    /// Status conditions following K8s conventions
    #[serde(default)]
    pub conditions: Vec<TenantCondition>,
}

#[derive(Deserialize, Serialize, Clone, Debug, JsonSchema)]
pub struct TenantCondition {
    #[serde(rename = "type")]
    pub condition_type: String,
    pub status: String,
    #[serde(default)]
    pub message: Option<String>,
}

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

/// Apply desired state: ensure namespace, PVC, ServiceAccount, NetworkPolicy exist
async fn apply(tenant: Arc<Tenant>, tenant_ns: &str, ctx: Arc<Context>) -> Result<Action> {
    let client = ctx.client.clone();
    let name = tenant.name_any();
    let oref = tenant.object_ref(&());
    let ssapply = PatchParams::apply("tenant-operator").force();

    // 1. Ensure namespace
    let ns_api: Api<Namespace> = Api::all(client.clone());
    let ns = Namespace {
        metadata: ObjectMeta {
            name: Some(tenant_ns.to_string()),
            labels: Some(BTreeMap::from([
                ("openclaw.io/tenant".to_string(), name.clone()),
                (
                    "app.kubernetes.io/managed-by".to_string(),
                    "tenant-operator".to_string(),
                ),
            ])),
            ..Default::default()
        },
        ..Default::default()
    };
    ns_api
        .patch(tenant_ns, &ssapply, &Patch::Apply(ns))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured namespace {tenant_ns}");

    // 2. Ensure PVC (10Gi gp3)
    let pvc_api: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), tenant_ns);
    let pvc_patch: serde_json::Value = json!({
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {
            "name": format!("{name}-data"),
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "accessModes": ["ReadWriteOnce"],
            "storageClassName": "gp3",
            "resources": {
                "requests": {
                    "storage": "10Gi"
                }
            }
        }
    });
    pvc_api
        .patch(&format!("{name}-data"), &ssapply, &Patch::Apply(pvc_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured PVC {name}-data in {tenant_ns}");

    // 3. Ensure ServiceAccount with Pod Identity annotation placeholder
    let sa_api: Api<ServiceAccount> = Api::namespaced(client.clone(), tenant_ns);
    let sa_patch: serde_json::Value = json!({
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        }
    });
    sa_api
        .patch(&name, &ssapply, &Patch::Apply(sa_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ServiceAccount {name} in {tenant_ns}");

    // 4. Ensure default-deny NetworkPolicy
    let np_api: Api<NetworkPolicy> = Api::namespaced(client.clone(), tenant_ns);
    let np_patch: serde_json::Value = json!({
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": "default-deny",
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "podSelector": {},
            "policyTypes": ["Ingress", "Egress"],
            "egress": [
                {
                    "ports": [
                        { "port": 53, "protocol": "UDP" },
                        { "port": 53, "protocol": "TCP" },
                        { "port": 443, "protocol": "TCP" }
                    ]
                }
            ]
        }
    });
    np_api
        .patch("default-deny", &ssapply, &Patch::Apply(np_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured NetworkPolicy default-deny in {tenant_ns}");

    // 5. Helm release: create values ConfigMap and run helm upgrade --install
    let helm_values = serde_yaml::to_string(&json!({
        "tenant": {
            "name": &name,
            "email": &tenant.spec.email,
            "skills": &tenant.spec.skills,
            "budget": tenant.spec.budget.as_ref().map(|b| b.monthly_usd).unwrap_or(100),
            "enabled": tenant.spec.enabled,
        }
    }))
    .map_err(|e| Error::HelmError(e.to_string()))?;

    let cm_api: Api<ConfigMap> = Api::namespaced(client.clone(), tenant_ns);
    let cm_patch: serde_json::Value = json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": format!("{name}-helm-values"),
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "data": {
            "values.yaml": helm_values
        }
    });
    cm_api
        .patch(
            &format!("{name}-helm-values"),
            &ssapply,
            &Patch::Apply(cm_patch),
        )
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured Helm values ConfigMap {name}-helm-values in {tenant_ns}");

    let mut helm_child = tokio::process::Command::new("helm")
        .args([
            "upgrade",
            "--install",
            &name,
            "openclaw/openclaw",
            "--namespace",
            tenant_ns,
            "--values",
            "/dev/stdin",
            "--wait",
            "--timeout",
            "5m",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| Error::HelmError(format!("Failed to spawn helm: {e}")))?;

    // Write values to stdin
    if let Some(mut stdin) = helm_child.stdin.take() {
        use tokio::io::AsyncWriteExt;
        stdin
            .write_all(helm_values.as_bytes())
            .await
            .map_err(|e| Error::HelmError(format!("Failed to write helm values: {e}")))?;
        drop(stdin);
    }

    let output = helm_child
        .wait_with_output()
        .await
        .map_err(|e| Error::HelmError(format!("Helm process error: {e}")))?;

    let helm_condition = if output.status.success() {
        info!("Helm release {name} deployed in {tenant_ns}");
        json!({ "type": "HelmReleaseReady", "status": "True" })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!("Helm release {name} failed: {stderr}");
        json!({ "type": "HelmReleaseReady", "status": "False", "message": stderr.to_string() })
    };

    // 6. Ensure KEDA HTTPScaledObject (scale-to-zero after 15m idle, max 1 replica)
    let hso_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("http.keda.sh", "v1alpha1", "HTTPScaledObject"),
        "httpscaledobjects",
    );
    let hso_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), tenant_ns, &hso_ar);
    let hso_name = format!("{name}-hso");
    let hso_patch: serde_json::Value = json!({
        "apiVersion": "http.keda.sh/v1alpha1",
        "kind": "HTTPScaledObject",
        "metadata": {
            "name": &hso_name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "hosts": [format!("{name}.openclaw.io")],
            "targetPendingRequests": 1,
            "scaledownPeriod": 900,
            "replicas": { "min": 0, "max": 1 },
            "scaleTargetRef": {
                "name": name,
                "kind": "Deployment",
                "apiVersion": "apps/v1"
            }
        }
    });
    let keda_condition = match hso_api
        .patch(&hso_name, &ssapply, &Patch::Apply(hso_patch))
        .await
    {
        Ok(_) => {
            info!("Ensured HTTPScaledObject {hso_name} in {tenant_ns}");
            json!({ "type": "KEDAReady", "status": "True" })
        }
        Err(e) => {
            warn!("HTTPScaledObject {hso_name} failed: {e}");
            json!({ "type": "KEDAReady", "status": "False", "message": e.to_string() })
        }
    };

    // 7. Update status
    let status = json!({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "status": {
            "phase": if tenant.spec.enabled { "Ready" } else { "Suspended" },
            "conditions": [
                { "type": "NamespaceReady", "status": "True" },
                { "type": "PVCBound", "status": "Unknown", "message": "Pending verification" },
                { "type": "NetworkPolicyApplied", "status": "True" },
                helm_condition,
                keda_condition
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
    let ns_api: Api<Namespace> = Api::all(client.clone());
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
