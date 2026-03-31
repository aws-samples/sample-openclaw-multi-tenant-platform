use crate::{Error, Result};
use kube::CustomResource;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

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
    printcolumn = r#"{"name":"Budget","type":"integer","jsonPath":".spec.budget.monthlyUSD"}"#,
    printcolumn = r#"{"name":"AlwaysOn","type":"boolean","jsonPath":".spec.alwaysOn"}"#
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
    /// Container image override (defaults to Operator env OPENCLAW_IMAGE)
    #[serde(default)]
    pub image: Option<TenantImage>,
    /// Pod resource requests and limits
    #[serde(default)]
    pub resources: Option<TenantResources>,
    /// Extra environment variables injected into the main container
    #[serde(default)]
    pub env: Option<BTreeMap<String, String>>,
    /// Keep Pod running 24/7 (skip scale-to-zero). For tenants with cron jobs.
    #[serde(rename = "alwaysOn", default)]
    pub always_on: bool,
}

pub fn default_enabled() -> bool {
    true
}

#[derive(Deserialize, Serialize, Clone, Debug, Default, JsonSchema)]
pub struct TenantBudget {
    /// Monthly spend cap in USD
    #[serde(rename = "monthlyUSD", default = "default_budget")]
    pub monthly_usd: i64,
}

pub fn default_budget() -> i64 {
    100
}

/// Container image configuration for the tenant
#[derive(Deserialize, Serialize, Clone, Debug, Default, JsonSchema)]
pub struct TenantImage {
    /// Image repository (defaults to Operator OPENCLAW_IMAGE env)
    #[serde(default)]
    pub repository: Option<String>,
    /// Image tag override
    #[serde(default)]
    pub tag: Option<String>,
    /// Pull policy (default: IfNotPresent)
    #[serde(rename = "pullPolicy", default = "default_pull_policy")]
    pub pull_policy: String,
}

pub fn default_pull_policy() -> String {
    "IfNotPresent".to_string()
}

/// Resource requests and limits for the tenant pod
#[derive(Deserialize, Serialize, Clone, Debug, Default, JsonSchema)]
pub struct TenantResources {
    #[serde(default)]
    pub requests: Option<ResourceSpec>,
    #[serde(default)]
    pub limits: Option<ResourceSpec>,
}

/// CPU and memory specification
#[derive(Deserialize, Serialize, Clone, Debug, Default, JsonSchema)]
pub struct ResourceSpec {
    #[serde(default)]
    pub cpu: Option<String>,
    #[serde(default)]
    pub memory: Option<String>,
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

/// Helper to require an environment variable, returning HelmError if missing
pub fn require_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| Error::HelmError(format!("{key} not set")))
}
