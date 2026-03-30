use crate::{Error, Metrics, Result};
use futures::StreamExt;
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{
    ConfigMap, Namespace, PersistentVolumeClaim, ResourceQuota, Service, ServiceAccount,
};
use k8s_openapi::api::networking::v1::NetworkPolicy;
use k8s_openapi::api::policy::v1::PodDisruptionBudget;

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
    /// Container image override (defaults to Operator env OPENCLAW_IMAGE)
    #[serde(default)]
    pub image: Option<TenantImage>,
    /// Pod resource requests and limits
    #[serde(default)]
    pub resources: Option<TenantResources>,
    /// Extra environment variables injected into the main container
    #[serde(default)]
    pub env: Option<BTreeMap<String, String>>,
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

fn default_pull_policy() -> String {
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
fn require_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| Error::HelmError(format!("{key} not set")))
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

/// Apply desired state: ensure namespace, PVC, ServiceAccount, ArgoCD Application, KEDA HSO
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

    // 4. Ensure ConfigMap (openclaw.json + bash_aliases + fetch-secret.mjs)
    let gateway_domain = std::env::var("GATEWAY_DOMAIN").unwrap_or_default();
    let openclaw_image = std::env::var("OPENCLAW_IMAGE")
        .unwrap_or_else(|_| "ghcr.io/openclaw/openclaw:latest".into());

    let base_path = format!("/t/{name}");
    let allowed_origin = if gateway_domain.is_empty() {
        String::new()
    } else {
        format!("https://{gateway_domain}")
    };

    let openclaw_config = json!({
        "gateway": {
            "port": 18789,
            "mode": "local",
            "bind": "lan",
            "trustedProxies": ["10.0.0.0/16"],
            "auth": { "mode": "token" },
            "controlUi": {
                "basePath": &base_path,
                "allowedOrigins": if allowed_origin.is_empty() { vec![] } else { vec![&allowed_origin] },
                "dangerouslyDisableDeviceAuth": true
            }
        },
        "browser": { "enabled": false },
        "tools": {
            "profile": "full",
            "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
            "fs": { "workspaceOnly": true },
            "exec": { "security": "deny" },
            "elevated": { "enabled": false },
            "web": { "search": { "enabled": false }, "fetch": { "enabled": true } }
        },
        "logging": {
            "level": "info",
            "consoleLevel": "info",
            "consoleStyle": "compact",
            "redactSensitive": "tools"
        },
        "agents": {
            "defaults": {
                "workspace": "/home/node/.openclaw/workspace",
                "userTimezone": "UTC",
                "timeoutSeconds": 600,
                "maxConcurrent": 1,
                "model": {
                    "primary": "amazon-bedrock/us.anthropic.claude-opus-4-6-v1",
                    "fallbacks": [
                        "amazon-bedrock/us.anthropic.claude-sonnet-4-6",
                        "amazon-bedrock/deepseek.v3.2"
                    ]
                }
            },
            "list": [{ "id": "main", "default": true, "identity": { "name": "OpenClaw", "emoji": "\u{1f99e}" } }]
        },
        "models": { "bedrockDiscovery": { "enabled": true, "region": "us-west-2" } },
        "session": {
            "scope": "per-sender",
            "store": "/home/node/.openclaw/sessions",
            "reset": { "mode": "idle", "idleMinutes": 60 }
        },
        "secrets": {
            "providers": {
                "aws-sm": {
                    "source": "exec",
                    "command": "/usr/local/bin/node",
                    "args": ["/home/node/.openclaw/workspace/bin/fetch-secret.mjs"],
                    "timeoutMs": 10000,
                    "passEnv": [
                        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
                        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
                        "AWS_REGION",
                        "TENANT_NAMESPACE",
                        "NODE_PATH"
                    ]
                }
            }
        }
    });

    const FETCH_SECRET_MJS: &str = r#"#!/usr/bin/env node
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
const input = JSON.parse(await new Response(process.stdin).text());
const sm = new SecretsManagerClient({ region: process.env.AWS_REGION });
const ns = process.env.TENANT_NAMESPACE;
const result = {};
for (const id of input.ids) {
  const { SecretString } = await sm.send(new GetSecretValueCommand({ SecretId: `openclaw/${ns}/${id}` }));
  result[id] = SecretString;
}
process.stdout.write(JSON.stringify(result));
"#;

    let cm_api: Api<ConfigMap> = Api::namespaced(client.clone(), tenant_ns);
    let cm_patch: serde_json::Value = json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": &name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": &name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "data": {
            "openclaw.json": serde_json::to_string_pretty(&openclaw_config)
                .map_err(|e| Error::HelmError(e.to_string()))?,
            "bash_aliases": "alias openclaw='node /app/dist/index.js'\n",
            "fetch-secret.mjs": FETCH_SECRET_MJS
        }
    });
    cm_api
        .patch(&name, &ssapply, &Patch::Apply(cm_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ConfigMap {name} in {tenant_ns}");

    // 5. Ensure Deployment
    let (img_repo, img_tag, img_pull_policy) = match &tenant.spec.image {
        Some(img) => (
            img.repository.as_deref().unwrap_or(&openclaw_image),
            img.tag.as_deref().unwrap_or("latest"),
            img.pull_policy.as_str(),
        ),
        None => (openclaw_image.as_str(), "latest", "IfNotPresent"),
    };
    let full_image = if img_repo.contains(':') {
        img_repo.to_string()
    } else {
        format!("{img_repo}:{img_tag}")
    };

    let (req_cpu, req_mem) = match tenant
        .spec
        .resources
        .as_ref()
        .and_then(|r| r.requests.as_ref())
    {
        Some(r) => (
            r.cpu.as_deref().unwrap_or("200m"),
            r.memory.as_deref().unwrap_or("512Mi"),
        ),
        None => ("200m", "512Mi"),
    };
    let (lim_cpu, lim_mem) = match tenant
        .spec
        .resources
        .as_ref()
        .and_then(|r| r.limits.as_ref())
    {
        Some(r) => (
            r.cpu.as_deref().unwrap_or("2"),
            r.memory.as_deref().unwrap_or("2Gi"),
        ),
        None => ("2", "2Gi"),
    };

    // Build skill install commands for init-skills (validate names to prevent shell injection)
    for s in &tenant.spec.skills {
        if !s
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Err(Error::ValidationError(format!("Invalid skill name: {s}")));
        }
    }
    let skill_cmds = tenant
        .spec
        .skills
        .iter()
        .map(|s| {
            format!(
                "if [ ! -d \"skills/{s}\" ]; then npx -y clawhub install \"{s}\" --no-input || true; fi"
            )
        })
        .collect::<Vec<_>>()
        .join("\n          ");
    let init_skills_script = format!(
        "mkdir -p /home/node/.openclaw/workspace/skills\ncd /home/node/.openclaw/workspace\n{skill_cmds}"
    );

    // Build extra env vars from tenant spec
    let mut container_env: Vec<serde_json::Value> = vec![
        json!({ "name": "TENANT_NAMESPACE", "valueFrom": { "fieldRef": { "fieldPath": "metadata.namespace" } } }),
        json!({ "name": "NODE_PATH", "value": "/home/node/.openclaw/workspace/node_modules" }),
    ];
    if let Some(extra) = &tenant.spec.env {
        for (k, v) in extra {
            container_env.push(json!({ "name": k, "value": v }));
        }
    }

    let deploy_api: Api<Deployment> = Api::namespaced(client.clone(), tenant_ns);
    let deploy_patch: serde_json::Value = json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": &name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": &name,
                "app.kubernetes.io/managed-by": "tenant-operator",
                "app.kubernetes.io/name": &name,
                "app.kubernetes.io/instance": &name
            }
        },
        "spec": {
            "replicas": 1,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": &name,
                    "app.kubernetes.io/instance": &name
                }
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": &name,
                        "app.kubernetes.io/instance": &name,
                        "openclaw.io/tenant": &name
                    }
                },
                "spec": {
                    "serviceAccountName": &name,
                    "securityContext": {
                        "fsGroup": 1000,
                        "runAsUser": 1000,
                        "runAsNonRoot": true
                    },
                    "initContainers": [
                        {
                            "name": "init-config",
                            "image": &full_image,
                            "resources": {
                                "limits": { "cpu": "500m", "memory": "256Mi" },
                                "requests": { "cpu": "100m", "memory": "128Mi" }
                            },
                            "command": ["sh", "-c",
                                "mkdir -p /home/node/.openclaw && cp /config/openclaw.json /home/node/.openclaw/openclaw.json"
                            ],
                            "volumeMounts": [
                                { "name": "config", "mountPath": "/config" },
                                { "name": "data", "mountPath": "/home/node/.openclaw" },
                                { "name": "tmp", "mountPath": "/tmp" }
                            ]
                        },
                        {
                            "name": "init-skills",
                            "image": &full_image,
                            "resources": {
                                "limits": { "cpu": "1", "memory": "1Gi" },
                                "requests": { "cpu": "200m", "memory": "256Mi" }
                            },
                            "command": ["sh", "-c", &init_skills_script],
                            "env": [
                                { "name": "HOME", "value": "/tmp" },
                                { "name": "NPM_CONFIG_CACHE", "value": "/tmp/.npm" }
                            ],
                            "volumeMounts": [
                                { "name": "data", "mountPath": "/home/node/.openclaw" },
                                { "name": "tmp", "mountPath": "/tmp" }
                            ]
                        },
                        {
                            "name": "init-tools",
                            "image": &full_image,
                            "resources": {
                                "limits": { "cpu": "1", "memory": "1Gi" },
                                "requests": { "cpu": "200m", "memory": "256Mi" }
                            },
                            "command": ["sh", "-c"],
                            "args": [concat!(
                                "mkdir -p /home/node/.openclaw/workspace/bin\n",
                                "if [ ! -f /home/node/.openclaw/workspace/node_modules/@aws-sdk/client-secrets-manager/dist-cjs/index.js ]; then\n",
                                "  cd /home/node/.openclaw/workspace && npm install --no-save @aws-sdk/client-secrets-manager 2>/dev/null\n",
                                "fi\n",
                                "for IMDS_FILE in \\\n",
                                "  /home/node/.openclaw/workspace/node_modules/@smithy/credential-provider-imds/dist-cjs/index.js \\\n",
                                "  /app/node_modules/@smithy/credential-provider-imds/dist-cjs/index.js; do\n",
                                "  if [ -f \"$IMDS_FILE\" ] && ! grep -q \"169.254.170.23\" \"$IMDS_FILE\"; then\n",
                                "    sed -i 's/\"127.0.0.1\": true,/\"127.0.0.1\": true, \"169.254.170.23\": true,/' \"$IMDS_FILE\"\n",
                                "  fi\n",
                                "done\n",
                                "cp /config/fetch-secret.mjs /home/node/.openclaw/workspace/bin/fetch-secret.mjs\n",
                                "chmod 700 /home/node/.openclaw/workspace/bin/fetch-secret.mjs"
                            )],
                            "volumeMounts": [
                                { "name": "config", "mountPath": "/config" },
                                { "name": "data", "mountPath": "/home/node/.openclaw" },
                                { "name": "tmp", "mountPath": "/tmp" }
                            ]
                        }
                    ],
                    "containers": [{
                        "name": "main",
                        "image": &full_image,
                        "imagePullPolicy": img_pull_policy,
                        "command": ["node", "dist/index.js"],
                        "args": ["gateway", "--port", "18789", "--bind", "lan"],
                        "ports": [{ "containerPort": 18789, "protocol": "TCP" }],
                        "livenessProbe": {
                            "httpGet": { "path": "/healthz", "port": 18789 },
                            "initialDelaySeconds": 30,
                            "periodSeconds": 30,
                            "timeoutSeconds": 5
                        },
                        "readinessProbe": {
                            "tcpSocket": { "port": 18789 },
                            "initialDelaySeconds": 10,
                            "periodSeconds": 10,
                            "timeoutSeconds": 5
                        },
                        "startupProbe": {
                            "tcpSocket": { "port": 18789 },
                            "initialDelaySeconds": 5,
                            "periodSeconds": 5,
                            "timeoutSeconds": 5,
                            "failureThreshold": 30
                        },
                        "resources": {
                            "requests": { "cpu": req_cpu, "memory": req_mem },
                            "limits": { "cpu": lim_cpu, "memory": lim_mem }
                        },
                        "env": container_env,
                        "securityContext": {
                            "readOnlyRootFilesystem": true
                        },
                        "volumeMounts": [
                            { "name": "data", "mountPath": "/home/node/.openclaw" },
                            { "name": "tmp", "mountPath": "/tmp" },
                            { "name": "bash-aliases", "mountPath": "/home/node/.bash_aliases", "subPath": "bash_aliases" }
                        ]
                    }],
                    "volumes": [
                        { "name": "config", "configMap": { "name": &name } },
                        { "name": "bash-aliases", "configMap": { "name": &name } },
                        { "name": "data", "persistentVolumeClaim": { "claimName": format!("{name}-data") } },
                        { "name": "tmp", "emptyDir": {} }
                    ]
                }
            }
        }
    });
    deploy_api
        .patch(&name, &ssapply, &Patch::Apply(deploy_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured Deployment {name} in {tenant_ns}");

    // 6. Ensure Service (ClusterIP, port 18789)
    let svc_api: Api<Service> = Api::namespaced(client.clone(), tenant_ns);
    let svc_patch: serde_json::Value = json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": &name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": &name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "type": "ClusterIP",
            "ports": [{
                "port": 18789,
                "targetPort": 18789,
                "protocol": "TCP",
                "name": "gateway"
            }],
            "selector": {
                "app.kubernetes.io/name": &name,
                "app.kubernetes.io/instance": &name
            }
        }
    });
    svc_api
        .patch(&name, &ssapply, &Patch::Apply(svc_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured Service {name} in {tenant_ns}");

    // 7. NetworkPolicy — restrict ingress/egress per tenant namespace
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
    np_api
        .patch(&name, &ssapply, &Patch::Apply(np_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured NetworkPolicy {name} in {tenant_ns}");

    // 8. ResourceQuota — cap CPU/memory/pods per tenant namespace
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
    rq_api
        .patch(&name, &ssapply, &Patch::Apply(rq_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ResourceQuota {name} in {tenant_ns}");

    // 9. PDB — ensure minAvailable=1 during voluntary disruptions
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
    pdb_api
        .patch(&name, &ssapply, &Patch::Apply(pdb_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured PDB {name} in {tenant_ns}");

    // 10. ArgoCD Application — delegates Helm chart deployment to ArgoCD
    let cognito_pool_arn = require_env("COGNITO_POOL_ARN")?;
    let cognito_client_id = require_env("COGNITO_CLIENT_ID")?;
    let cognito_domain = require_env("COGNITO_DOMAIN")?;
    let chart_repo = require_env("CHART_REPO")?;
    let chart_version = std::env::var("CHART_VERSION").unwrap_or_else(|_| "1.3.14".into());

    // 11. HTTPRoute — route traffic to tenant service via Gateway API
    let httproute_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("gateway.networking.k8s.io", "v1", "HTTPRoute"),
        "httproutes",
    );
    let httproute_api: Api<DynamicObject> =
        Api::namespaced_with(client.clone(), tenant_ns, &httproute_ar);

    let mut httproute_rules = vec![json!({
        "matches": [{ "path": { "type": "PathPrefix", "value": format!("/t/{name}") } }],
        "backendRefs": [{ "name": &name, "port": 18789 }]
    })];
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
        .patch(&name, &ssapply, &Patch::Apply(httproute_patch))
        .await
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

    // 12. ListenerRuleConfiguration — Cognito auth (conditional)
    let lrc_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(
            "gateway.k8s.aws",
            "v1beta1",
            "ListenerRuleConfiguration",
        ),
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
        match lrc_api
            .patch(&lrc_name, &ssapply, &Patch::Apply(lrc_patch))
            .await
        {
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

    // 13. TargetGroupConfiguration — health check config for ALB
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
        .patch(&tgc_name, &ssapply, &Patch::Apply(tgc_patch))
        .await
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

    let helm_values = serde_yaml::to_string(&json!({
        "tenant": {
            "name": &name,
            "email": &tenant.spec.email,
            "skills": &tenant.spec.skills,
            "budget": tenant.spec.budget.as_ref().map(|b| b.monthly_usd).unwrap_or(100),
            "enabled": tenant.spec.enabled,
        },
        "gateway": {
            "enabled": true,
            "gatewayName": "openclaw-gateway",
            "gatewayNamespace": "openclaw-system",
            "domain": &gateway_domain,
            "cognito": {
                "enabled": true,
                "userPoolArn": &cognito_pool_arn,
                "clientId": &cognito_client_id,
                "domain": &cognito_domain,
            }
        }
    }))
    .map_err(|e| Error::HelmError(e.to_string()))?;

    let app_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("argoproj.io", "v1alpha1", "Application"),
        "applications",
    );
    let app_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), "argocd", &app_ar);
    let app_patch: serde_json::Value = json!({
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "metadata": {
            "name": format!("tenant-{name}"),
            "namespace": "argocd",
            "labels": {
                "openclaw.io/tenant": &name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "project": "default",
            "source": {
                "repoURL": &chart_repo,
                "path": "helm/charts/openclaw-platform",
                "targetRevision": &chart_version,
                "helm": {
                    "values": &helm_values
                }
            },
            "destination": {
                "name": "in-cluster",
                "namespace": tenant_ns
            },
            "syncPolicy": {
                "automated": {
                    "prune": true,
                    "selfHeal": true
                },
                "syncOptions": ["CreateNamespace=false"]
            }
        }
    });
    let argocd_condition = match app_api
        .patch(
            &format!("tenant-{name}"),
            &ssapply,
            &Patch::Apply(app_patch),
        )
        .await
    {
        Ok(_) => {
            info!("Ensured ArgoCD Application tenant-{name}");
            json!({ "type": "ArgoAppReady", "status": "True" })
        }
        Err(e) => {
            warn!("ArgoCD Application tenant-{name} failed: {e}");
            json!({ "type": "ArgoAppReady", "status": "False", "message": e.to_string() })
        }
    };

    // 9. Ensure KEDA HTTPScaledObject (scale-to-zero after 15m idle, max 1 replica)
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
            "hosts": [if gateway_domain.is_empty() { name.clone() } else { format!("{name}.{gateway_domain}") }],
            "targetPendingRequests": 1,
            "scaledownPeriod": 900,
            "replicas": { "min": 0, "max": 1 },
            "scaleTargetRef": {
                "name": name,
                "kind": "Deployment",
                "apiVersion": "apps/v1",
                "service": name,
                "port": 18789
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

    // 10. Update status
    let status = json!({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "status": {
            "phase": if tenant.spec.enabled { "Ready" } else { "Suspended" },
            "conditions": [
                { "type": "NamespaceReady", "status": "True" },
                { "type": "PVCBound", "status": "Unknown", "message": "Pending verification" },
                argocd_condition,
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

    // Delete ArgoCD Application first (stops sync before namespace deletion)
    let app_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("argoproj.io", "v1alpha1", "Application"),
        "applications",
    );
    let app_api: Api<DynamicObject> = Api::namespaced_with(client.clone(), "argocd", &app_ar);
    let app_name = format!("tenant-{name}");
    if app_api
        .get_opt(&app_name)
        .await
        .map_err(Error::KubeError)?
        .is_some()
    {
        app_api
            .delete(&app_name, &Default::default())
            .await
            .map_err(Error::KubeError)?;
        info!("Deleted ArgoCD Application {app_name}");
    }

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
