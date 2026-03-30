# Security Deep Dive

> OpenClaw Platform — defense-in-depth across 10 layers, from edge to audit trail.

---

## Security Layers Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Edge         CloudFront + WAF (Common Rules + rate limit)          │
│  2. Signup       Turnstile CAPTCHA + email domain restriction          │
│  3. Network      Internet-facing ALB (CF-only SG) + NetworkPolicy      │
│  4. Auth         Cognito signup + local token auth + 3-layer origin    │
│  5. Tenant       Namespace isolation + ABAC + ResourceQuota            │
│  6. Secrets      exec SecretRef — on-demand fetch, never persisted     │
│  7. LLM          Bedrock via Pod Identity — zero API keys              │
│  8. Cost         Per-tenant budget enforcement + daily Lambda scan     │
│  9. Data         PVC persistence + daily EBS snapshots + 7d retention  │
│ 10. Audit        CloudTrail → S3 → Athena (Bedrock-specific trail)    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Edge Protection

**What it does**: Filters malicious traffic before it reaches the application.

**How it's configured**:
- CloudFront distribution terminates TLS at edge (ACM cert in us-east-1)
- WAF WebACL (REGIONAL scope) attached to ALB with two rules:
  - `AWSManagedRulesCommonRuleSet` — OWASP Top 10 coverage (SQLi, XSS, path traversal, etc.)
  - `RateLimit` — 2000 requests per 5 minutes per IP, then block

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `WafAcl` (CfnWebACL)

**Helm reference**: N/A (WAF is infrastructure-level)

**Script**: `scripts/setup-waf.sh` — associates WAF WebACL with the dynamic ALB ARN

**Attacks mitigated**: DDoS (rate limiting), SQLi, XSS, bad bots, path traversal

---

## Layer 2: Signup Protection

**What it does**: Prevents unauthorized account creation and bot signups.

**How it's configured**:
- Pre-signup Lambda validates email domain against allowlist (`ALLOWED_DOMAINS` env var)
- Cloudflare Turnstile CAPTCHA verification (if `TURNSTILE_SECRET` is set)
- `autoConfirmUser: true` — email domain restriction is the trust gate, no admin approval required
  > **Note**: The `allowedEmailDomains` setting in `cdk.json` is the primary access control. Ensure this is set to your company domain only.
- SNS notification on every signup attempt

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `PreSignupFn`

**Lambda source**: `cdk/lambda/pre-signup/index.py`

**Attacks mitigated**: Bot signups, unauthorized domain access, account enumeration (rejected domains get generic error)

---

## Layer 3: Network Isolation

**What it does**: Ensures pods are unreachable from the internet and isolated from each other.

**How it's configured**:
- VPC with public/private subnet separation (2 AZs, /24 subnets)
- Pods run exclusively in private subnets
- ALB is **internet-facing** with 3-layer origin protection:
  - L3/L4: ALB Security Group allows only CloudFront managed prefix list
  - L7: WAF validates `X-Verify-Origin` custom header from CloudFront
  - Transport: HTTPS-only origin protocol
- Traffic path: Internet → CloudFront → ALB (public, CF-only SG) → Pod
- 2 NAT Gateways (HA) for outbound internet
- VPC Flow Logs enabled (all traffic → CloudWatch Logs)
- NetworkPolicy per tenant namespace:

```yaml
# Ingress: same namespace + kube-system (ALB health checks) only
# Egress whitelist:
#   DNS         → any namespace, UDP/TCP 53
#   Pod Identity → 169.254.170.23/32, TCP 80
#   IMDS        → 169.254.169.254/32, TCP 80
#   HTTPS       → 0.0.0.0/0 except 10.0.0.0/8, TCP 443
#   Same-ns     → podSelector: {}
# Everything else: implicit deny
```

The `10.0.0.0/8` exception in HTTPS egress blocks cross-tenant pod traffic over port 443 while allowing external AWS service endpoints (Bedrock, Secrets Manager, container registries).

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `Vpc`, `VpcFlowLog`

**Helm reference**: `helm/charts/openclaw-platform/templates/networkpolicy.yaml`

**Attacks mitigated**: Direct pod access from internet, cross-tenant lateral movement, pod-to-pod data exfiltration

---

## Layer 4: Authentication

**What it does**: Ensures access is controlled before reaching a pod.

**How it's configured**:
- Cognito User Pool for signup identity management
- OpenClaw gateway runs in `local` auth mode with token authentication
- 3-layer origin protection: CloudFront prefix list SG + WAF header validation + HTTPS-only
- Path-based routing via Gateway API HTTPRoute
- Traffic path: Internet → CloudFront → internet-facing ALB (CF-only) → HTTPRoute → Pod

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `UserPool` (imported)

**Helm reference**: `helm/charts/openclaw-platform/values.yaml` → `config.gateway.auth`

**Helm template**: `helm/charts/openclaw-platform/templates/httproute.yaml`

**Attacks mitigated**: Direct pod access from internet (CF-only SG), unauthorized access (CloudFront + WAF + local auth)

---

## Layer 5: Tenant Isolation

**What it does**: Prevents one tenant from accessing another tenant's resources.

**How it's configured**:
- One Kubernetes namespace per tenant (`openclaw-{tenant}`)
- ResourceQuota per namespace: CPU 4 cores, memory 8Gi, max 10 pods
- NetworkPolicy: default-deny + explicit allowlist (see Layer 3)
- IAM ABAC: `aws:PrincipalTag/kubernetes-namespace` must match `secretsmanager:ResourceTag/tenant-namespace`
- Separate ServiceAccount per tenant → Pod Identity Association → shared `OpenClawTenantRole` with ABAC tags
- PodDisruptionBudget: `minAvailable: 1`

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `TenantRole` (ABAC policy)

**Helm reference**:
- `helm/charts/openclaw-platform/templates/resourcequota.yaml`
- `helm/charts/openclaw-platform/templates/serviceaccount.yaml`
- `helm/charts/openclaw-platform/templates/networkpolicy.yaml`

**Attacks mitigated**: Noisy neighbor (ResourceQuota), cross-tenant secret access (ABAC), cross-tenant network access (NetworkPolicy)

---

## Layer 6: Secrets Management

**What it does**: Provides on-demand secret access without persisting credentials on disk.

**How it's configured**:
- Secrets stored in AWS Secrets Manager with path convention: `openclaw/{tenant}/{secret-name}`
- Each secret tagged with `tenant-namespace: openclaw-{tenant}`
- `exec SecretRef` pattern: OpenClaw invokes `fetch-secret.mjs` on demand
- `fetch-secret.mjs` uses Pod Identity → STS AssumeRole → GetSecretValue
- ABAC policy ensures tenant can only read its own secrets
- Credentials are temporary (STS) — no static keys anywhere

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `SecretsManagerABAC` policy statement

**Helm reference**: `helm/charts/openclaw-platform/values.yaml` → `config.secrets.providers`

**Script**: `fetch-secret.mjs` embedded in Helm values → deployed via init-tools container

**Attacks mitigated**: Secret leakage (never written to disk), credential theft (temporary STS tokens), cross-tenant secret access (ABAC)

---

## Layer 7: LLM Access Control

**What it does**: Provides LLM access without API keys, with model-level control.

**How it's configured**:
- Amazon Bedrock accessed via Pod Identity — zero API keys in config or environment
- `OpenClawTenantRole` grants `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`
- Cross-region inference profiles for model routing
- Model discovery: `bedrock:ListFoundationModels`, `bedrock:ListInferenceProfiles`
- OpenClaw application-level controls:
  - `tool_policy: deny` — explicit tool allowlist only
  - `exec: deny` — no shell execution by default
  - `elevated: disabled` — no privilege escalation
  - `fs: workspaceOnly` — filesystem restricted to workspace directory

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `BedrockInvoke`, `BedrockDiscovery` policy statements

**Helm reference**: `helm/charts/openclaw-platform/values.yaml` → `config.tools`

**Attacks mitigated**: API key leakage (none exist), prompt injection leading to system access (tool restrictions), unauthorized model access (IAM-controlled)

---

## Layer 8: Cost Control

**What it does**: Prevents runaway LLM costs with per-tenant budgets.

**How it's configured**:
- Daily Lambda (`CostEnforcerFn`) queries CloudWatch Logs Insights for per-namespace Bedrock token usage
- Per-model pricing table (Opus, Sonnet, DeepSeek, etc.)
- Budget read from Secrets Manager tag `budget-usd` (default: $100/month)
- Alerts at 80% and 100% budget via SNS
- Per-tenant monthly cost report: `scripts/usage-report.sh --month YYYY-MM`

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `CostEnforcerFn`, `CostEnforcerSchedule`

**Lambda source**: `cdk/lambda/cost-enforcer/index.py`

**Attacks mitigated**: Runaway LLM costs, abuse by compromised tenant, budget overruns

---

## Layer 9: Data Protection

**What it does**: Ensures tenant data survives pod restarts, scale-to-zero, and failures.

**How it's configured**:
- PVC (gp3 EBS) per tenant — persists across pod restarts and scale-to-zero
- Daily EBS snapshot CronJob with 7-day retention
- `EBSSnapshotRole` with Pod Identity for snapshot operations
- Backup/restore scripts: `scripts/backup-tenant.sh`, `scripts/restore-tenant.sh`
- Container runs as non-root (UID 1000) with `fsGroup: 1000`
- `runAsNonRoot: true` enforced in pod security context

**CDK reference**: `cdk/lib/eks-cluster-stack.ts` → `EbsSnapshotRole`, `Gp3StorageClass`

**Helm reference**:
- `helm/charts/openclaw-platform/templates/deployment.yaml` → `securityContext`
- `helm/charts/openclaw-platform/templates/pvc.yaml`

**Scripts**: `scripts/pvc-backup-cronjob.yaml`, `scripts/setup-pvc-backup.sh`

**Attacks mitigated**: Data loss from pod crashes, accidental deletion (snapshot recovery), privilege escalation via root container

---

## Layer 10: Audit Trail

**What it does**: Records all Bedrock API calls for compliance and forensics.

**How it's configured**:
- Dedicated CloudTrail trail (`openclaw-bedrock-audit`) — Bedrock events only
- Advanced event selectors: `bedrock.amazonaws.com` + `bedrock-runtime.amazonaws.com`
- Logs stored in S3 bucket: `openclaw-audit-logs-{account}-{region}`
- Athena database + table for SQL queries over audit logs
- CloudWatch Container Insights for pod-level metrics and application logs
- EKS control plane logging: all 5 types (api, audit, authenticator, controllerManager, scheduler)

**Script**: `scripts/setup-audit-logging.sh`

**Example Athena query**:
```sql
SELECT eventtime, eventname, useridentity.arn
FROM openclaw_audit.cloudtrail_bedrock
WHERE eventsource = 'bedrock-runtime.amazonaws.com'
ORDER BY eventtime DESC LIMIT 20;
```

**Attacks mitigated**: Undetected unauthorized access, compliance violations, forensic gaps

---

## Threat Model

### Attacks Mitigated

| Attack Vector | Mitigation |
|---------------|------------|
| DDoS | CloudFront edge caching + WAF rate limiting (2000 req/5min/IP) |
| SQLi / XSS | WAF AWSManagedRulesCommonRuleSet |
| Bot signups | Cloudflare Turnstile CAPTCHA + email domain allowlist |
| Unauthenticated access | 3-layer origin protection: CF prefix list SG + WAF header + HTTPS |
| Cross-tenant data access | Namespace isolation + NetworkPolicy + ABAC on Secrets Manager |
| Cross-tenant network | NetworkPolicy blocks 10.0.0.0/8 on egress port 443 |
| API key leakage | Zero API keys — all access via Pod Identity + STS temporary credentials |
| Secret persistence on disk | exec SecretRef — fetched on demand, returned via stdout, never written |
| Prompt injection → system access | `exec: deny`, `elevated: disabled`, `fs: workspaceOnly`, explicit tool allowlist |
| Runaway LLM costs | Daily cost enforcer Lambda + per-tenant budget + SNS alerts |
| Data loss | PVC persistence + daily EBS snapshots + 7-day retention |
| Privilege escalation | Non-root container (UID 1000), `runAsNonRoot: true` |
| Unauthorized Bedrock usage | CloudTrail audit trail + Athena queryable logs |
| Karpenter subnet confusion | EC2NodeClass requires both `internal-elb` AND cluster-owned tags |

### Attack Surface Diagram

```
Internet ──► CloudFront ──► ALB (internet-facing, CF-only SG) ──► Pod
   │              │           │                                     │
   │         TLS termination  WAF: origin header verify         NetworkPolicy
   │         Edge caching     + Common Rules + Rate Limit        ABAC
   │                          SG: CF prefix list only            exec deny
   │                                                             fs: workspaceOnly
   │
   └──► Cognito ──► Pre-signup Lambda ──► Turnstile + domain check
                    Post-confirm Lambda ──► SM + Pod Identity + Tenant CR
```

---

## What's NOT Covered

These are known gaps — not yet implemented or intentionally deferred:

| Gap | Status | Notes |
|-----|--------|-------|
| MFA | Not implemented | Cognito supports MFA but not enabled. Recommended for admin accounts. |
| SAST/DAST | Not implemented | No static/dynamic application security testing in CI pipeline. Consider adding CodeGuru or Snyk. |
| `readOnlyRootFilesystem` | Partial | Not set on main container — OpenClaw writes to `/tmp` and PVC. Init containers use `emptyDir` for `/tmp`. |
| Pod Security Standards | Not enforced | No `PodSecurity` admission controller configured. Currently relies on Helm template defaults. |
| Image signing / verification | Not implemented | No Sigstore/Cosign verification on container images. |
| Secrets rotation | Not implemented | Secrets Manager secrets are not auto-rotated. |
| WAF logging | Not enabled | WAF sampled requests enabled but full logging to S3/CloudWatch not configured. |
| GuardDuty | Not enabled | No runtime threat detection for EKS. Run `scripts/setup-guardduty.sh` to enable. |
| KMS encryption | Default | EBS uses default encryption. No customer-managed KMS keys for S3 or Secrets Manager. |

---

## Compliance Considerations

### SOC 2 Readiness

| Control Area | Current State | Gap |
|-------------|---------------|-----|
| Access Control | Cognito + ABAC + Pod Identity | Add MFA for admin accounts |
| Encryption in Transit | TLS everywhere (CloudFront → ALB → Pod) | ✅ |
| Encryption at Rest | EBS default encryption, S3 default encryption | Consider CMK for sensitive data |
| Logging & Monitoring | CloudTrail + CloudWatch + VPC Flow Logs + SNS alerts | Enable WAF logging |
| Change Management | GitOps (ArgoCD) + CI/CD | ✅ cdk-nag, npm audit in CI |
| Supply Chain | GitHub Actions SHA-pinned, npm --ignore-scripts, cargo-deny | ✅ |
| Incident Response | SNS alerts + Athena queries | Document runbooks |
| Data Retention | 7-day EBS snapshots, CloudTrail in S3 | Define retention policy per data class |

### HIPAA Readiness

| Requirement | Current State | Gap |
|-------------|---------------|-----|
| PHI encryption at rest | EBS default encryption | Requires CMK + audit of key management |
| PHI encryption in transit | TLS everywhere | ✅ |
| Access logging | CloudTrail + Container Insights | Need comprehensive access logs for all PHI touchpoints |
| BAA | Not in place | Requires AWS BAA + Bedrock BAA eligibility check |
| Minimum necessary access | ABAC + namespace isolation | ✅ |
| Audit controls | CloudTrail + Athena | Need automated compliance reporting |
| Data backup | Daily EBS snapshots | Need documented recovery procedures + RTO/RPO |

> **Note**: HIPAA compliance requires a Business Associate Agreement (BAA) with AWS and verification that all services used (Bedrock, Secrets Manager, EKS, etc.) are HIPAA-eligible. This platform provides the technical controls but does not constitute HIPAA compliance on its own.
