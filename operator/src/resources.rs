use crate::types::TenantSpec;
use crate::{Error, Result};
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{
    ConfigMap, Namespace, PersistentVolumeClaim, ResourceQuota, Service, ServiceAccount,
};
use k8s_openapi::api::networking::v1::NetworkPolicy;
use k8s_openapi::api::policy::v1::PodDisruptionBudget;
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

pub async fn ensure_pvc(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let pvc_api: Api<PersistentVolumeClaim> = Api::namespaced(client, tenant_ns);
    let pvc_patch: Value = json!({
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
        .patch(&format!("{name}-data"), ssapply, &Patch::Apply(pvc_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured PVC {name}-data in {tenant_ns}");
    Ok(())
}

pub async fn ensure_service_account(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let sa_api: Api<ServiceAccount> = Api::namespaced(client, tenant_ns);
    let sa_patch: Value = json!({
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
        .patch(name, ssapply, &Patch::Apply(sa_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ServiceAccount {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_config_map(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let gateway_domain = std::env::var("GATEWAY_DOMAIN").unwrap_or_default();

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

    let cm_api: Api<ConfigMap> = Api::namespaced(client, tenant_ns);
    let cm_patch: Value = json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
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
        .patch(name, ssapply, &Patch::Apply(cm_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ConfigMap {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_deployment(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
    spec: &TenantSpec,
) -> Result<()> {
    let openclaw_image = std::env::var("OPENCLAW_IMAGE")
        .unwrap_or_else(|_| "ghcr.io/openclaw/openclaw:latest".into());

    let (img_repo, img_tag, img_pull_policy) = match &spec.image {
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

    let (req_cpu, req_mem) = match spec.resources.as_ref().and_then(|r| r.requests.as_ref()) {
        Some(r) => (
            r.cpu.as_deref().unwrap_or("200m"),
            r.memory.as_deref().unwrap_or("512Mi"),
        ),
        None => ("200m", "512Mi"),
    };
    let (lim_cpu, lim_mem) = match spec.resources.as_ref().and_then(|r| r.limits.as_ref()) {
        Some(r) => (
            r.cpu.as_deref().unwrap_or("2"),
            r.memory.as_deref().unwrap_or("2Gi"),
        ),
        None => ("2", "2Gi"),
    };

    // Build skill install commands for init-skills (validate names to prevent shell injection)
    for s in &spec.skills {
        if !s
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Err(Error::ValidationError(format!("Invalid skill name: {s}")));
        }
    }
    let skill_cmds = spec
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
    let mut container_env: Vec<Value> = vec![
        json!({ "name": "TENANT_NAMESPACE", "valueFrom": { "fieldRef": { "fieldPath": "metadata.namespace" } } }),
        json!({ "name": "NODE_PATH", "value": "/home/node/.openclaw/workspace/node_modules" }),
    ];
    if let Some(extra) = &spec.env {
        for (k, v) in extra {
            container_env.push(json!({ "name": k, "value": v }));
        }
    }

    let deploy_api: Api<Deployment> = Api::namespaced(client, tenant_ns);
    let deploy_patch: Value = json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator",
                "app.kubernetes.io/name": name,
                "app.kubernetes.io/instance": name
            }
        },
        "spec": {
            "replicas": 1,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": name,
                    "app.kubernetes.io/instance": name
                }
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": name,
                        "app.kubernetes.io/instance": name,
                        "openclaw.io/tenant": name
                    }
                },
                "spec": {
                    "serviceAccountName": name,
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
                        { "name": "config", "configMap": { "name": name } },
                        { "name": "bash-aliases", "configMap": { "name": name } },
                        { "name": "data", "persistentVolumeClaim": { "claimName": format!("{name}-data") } },
                        { "name": "tmp", "emptyDir": {} }
                    ]
                }
            }
        }
    });
    deploy_api
        .patch(name, ssapply, &Patch::Apply(deploy_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured Deployment {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_service(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let svc_api: Api<Service> = Api::namespaced(client, tenant_ns);
    let svc_patch: Value = json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
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
                "app.kubernetes.io/name": name,
                "app.kubernetes.io/instance": name
            }
        }
    });
    svc_api
        .patch(name, ssapply, &Patch::Apply(svc_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured Service {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_network_policy(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let np_api: Api<NetworkPolicy> = Api::namespaced(client, tenant_ns);
    let np_patch: Value = json!({
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
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
        .patch(name, ssapply, &Patch::Apply(np_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured NetworkPolicy {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_resource_quota(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let rq_api: Api<ResourceQuota> = Api::namespaced(client, tenant_ns);
    let rq_patch: Value = json!({
        "apiVersion": "v1",
        "kind": "ResourceQuota",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
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
        .patch(name, ssapply, &Patch::Apply(rq_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured ResourceQuota {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_pdb(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<()> {
    let pdb_api: Api<PodDisruptionBudget> = Api::namespaced(client, tenant_ns);
    let pdb_patch: Value = json!({
        "apiVersion": "policy/v1",
        "kind": "PodDisruptionBudget",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "minAvailable": 1,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/name": name,
                    "app.kubernetes.io/instance": name
                }
            }
        }
    });
    pdb_api
        .patch(name, ssapply, &Patch::Apply(pdb_patch))
        .await
        .map_err(Error::KubeError)?;
    info!("Ensured PDB {name} in {tenant_ns}");
    Ok(())
}

pub async fn ensure_httproute(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
    cognito_pool_arn: &str,
) -> Result<Value> {
    let httproute_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("gateway.networking.k8s.io", "v1", "HTTPRoute"),
        "httproutes",
    );
    let httproute_api: Api<DynamicObject> = Api::namespaced_with(client, tenant_ns, &httproute_ar);

    let mut httproute_rules = vec![json!({
        "matches": [{ "path": { "type": "PathPrefix", "value": format!("/t/{name}") } }],
        "backendRefs": [{ "name": name, "port": 18789 }]
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

    let httproute_patch: Value = json!({
        "apiVersion": "gateway.networking.k8s.io/v1",
        "kind": "HTTPRoute",
        "metadata": {
            "name": name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
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
    match httproute_api
        .patch(name, ssapply, &Patch::Apply(httproute_patch))
        .await
    {
        Ok(_) => {
            info!("Ensured HTTPRoute {name} in {tenant_ns}");
            Ok(json!({ "type": "HTTPRouteReady", "status": "True" }))
        }
        Err(e) => {
            warn!("HTTPRoute {name} failed: {e}");
            Ok(json!({ "type": "HTTPRouteReady", "status": "False", "message": e.to_string() }))
        }
    }
}

pub async fn ensure_lrc(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
    cognito_pool_arn: &str,
    cognito_client_id: &str,
    cognito_domain: &str,
) -> Result<Value> {
    let lrc_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(
            "gateway.k8s.aws",
            "v1beta1",
            "ListenerRuleConfiguration",
        ),
        "listenerruleconfigurations",
    );
    let lrc_api: Api<DynamicObject> = Api::namespaced_with(client, tenant_ns, &lrc_ar);
    let lrc_name = format!("{name}-cognito");

    if !cognito_pool_arn.is_empty() {
        let lrc_patch: Value = json!({
            "apiVersion": "gateway.k8s.aws/v1beta1",
            "kind": "ListenerRuleConfiguration",
            "metadata": {
                "name": &lrc_name,
                "namespace": tenant_ns,
                "labels": {
                    "openclaw.io/tenant": name,
                    "app.kubernetes.io/managed-by": "tenant-operator"
                }
            },
            "spec": {
                "actions": [{
                    "type": "authenticate-cognito",
                    "authenticateCognitoConfig": {
                        "userPoolArn": cognito_pool_arn,
                        "userPoolClientId": cognito_client_id,
                        "userPoolDomain": cognito_domain,
                        "onUnauthenticatedRequest": "authenticate",
                        "scope": "openid email profile",
                        "sessionTimeout": 604800
                    }
                }]
            }
        });
        match lrc_api
            .patch(&lrc_name, ssapply, &Patch::Apply(lrc_patch))
            .await
        {
            Ok(_) => {
                info!("Ensured ListenerRuleConfiguration {lrc_name} in {tenant_ns}");
                Ok(json!({ "type": "CognitoAuthReady", "status": "True" }))
            }
            Err(e) => {
                warn!("ListenerRuleConfiguration {lrc_name} failed: {e}");
                Ok(
                    json!({ "type": "CognitoAuthReady", "status": "False", "message": e.to_string() }),
                )
            }
        }
    } else {
        Ok(
            json!({ "type": "CognitoAuthReady", "status": "True", "message": "Cognito not configured, skipped" }),
        )
    }
}

pub async fn ensure_tgc(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<Value> {
    let tgc_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("gateway.k8s.aws", "v1beta1", "TargetGroupConfiguration"),
        "targetgroupconfigurations",
    );
    let tgc_api: Api<DynamicObject> = Api::namespaced_with(client, tenant_ns, &tgc_ar);
    let tgc_name = format!("{name}-tg");

    let tgc_patch: Value = json!({
        "apiVersion": "gateway.k8s.aws/v1beta1",
        "kind": "TargetGroupConfiguration",
        "metadata": {
            "name": &tgc_name,
            "namespace": tenant_ns,
            "labels": {
                "openclaw.io/tenant": name,
                "app.kubernetes.io/managed-by": "tenant-operator"
            }
        },
        "spec": {
            "targetReference": { "name": name },
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
    match tgc_api
        .patch(&tgc_name, ssapply, &Patch::Apply(tgc_patch))
        .await
    {
        Ok(_) => {
            info!("Ensured TargetGroupConfiguration {tgc_name} in {tenant_ns}");
            Ok(json!({ "type": "TargetGroupReady", "status": "True" }))
        }
        Err(e) => {
            warn!("TargetGroupConfiguration {tgc_name} failed: {e}");
            Ok(json!({ "type": "TargetGroupReady", "status": "False", "message": e.to_string() }))
        }
    }
}

pub async fn ensure_keda_hso(
    client: Client,
    name: &str,
    tenant_ns: &str,
    ssapply: &PatchParams,
) -> Result<Value> {
    let gateway_domain = std::env::var("GATEWAY_DOMAIN").unwrap_or_default();

    let hso_ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("http.keda.sh", "v1alpha1", "HTTPScaledObject"),
        "httpscaledobjects",
    );
    let hso_api: Api<DynamicObject> = Api::namespaced_with(client, tenant_ns, &hso_ar);
    let hso_name = format!("{name}-hso");
    let hso_patch: Value = json!({
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
            "hosts": [if gateway_domain.is_empty() { name.to_string() } else { format!("{name}.{gateway_domain}") }],
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
    match hso_api
        .patch(&hso_name, ssapply, &Patch::Apply(hso_patch))
        .await
    {
        Ok(_) => {
            info!("Ensured HTTPScaledObject {hso_name} in {tenant_ns}");
            Ok(json!({ "type": "KEDAReady", "status": "True" }))
        }
        Err(e) => {
            warn!("HTTPScaledObject {hso_name} failed: {e}");
            Ok(json!({ "type": "KEDAReady", "status": "False", "message": e.to_string() }))
        }
    }
}
