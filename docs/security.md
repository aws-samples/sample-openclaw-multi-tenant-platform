# Security Deep Dive

> Defense-in-depth across 10 layers, from edge to audit trail.

---

## Security Layers Overview

```
+-----------------------------------------------------------------------+
|  1. Edge         CloudFront + AWS WAF (Common Rules + rate limit)          |
|  2. Signup       AWS WAF Bot Control (opt-in) + email domain restriction     |
|  3. Network      Internet-facing ALB (CF prefix list SG) + NetworkPolicy|
|  4. Auth         Cognito signup + gateway token auth + CF prefix list   |
|  5. Tenant       Namespace isolation + ABAC + ResourceQuota            |
|  6. Secrets      exec SecretRef -- on-demand fetch, never persisted    |
|  7. LLM          Amazon Bedrock via Pod Identity -- zero API keys             |
|  8. Cost         Per-tenant budget enforcement + daily Lambda scan     |
|  9. Data         PVC persistence (EFS, multi-AZ) + AWS Backup  |
| 10. Audit        CloudTrail -> S3 -> Athena (Amazon Bedrock-specific trail)   |
+-----------------------------------------------------------------------+
```

---

## Layer 1: Edge Protection

Filters malicious traffic before it reaches the application.

- Amazon CloudFront distribution terminates TLS at edge (ACM cert in us-east-1)
- AWS WAF WebACL (REGIONAL scope) attached to ALB:
  - `AWSManagedRulesCommonRuleSet` -- OWASP Top 10 (SQLi, XSS, path traversal)
  - `RateLimit` -- 2000 requests per 5 minutes per IP

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `WafAcl`

**Script**: `scripts/post-deploy.sh` -- associates AWS WAF WebACL with the dynamic ALB ARN

---

## Layer 2: Signup Protection

Prevents unauthorized account creation and bot signups.

- Pre-signup AWS Lambda validates email domain against allowlist (`ALLOWED_DOMAINS`)
- Rate limiting: max 5 signups per email domain per hour
- AWS WAF Bot Control (if `enableBotControl` AWS CDK context is true)

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `PreSignupFn`

---

## Layer 3: Network Isolation

Designed to ensure tenant pods are isolated from each other and only reachable via the controlled traffic path.

- VPC with public/private subnet separation (2 AZs, /24 subnets)
- Pods run exclusively in private subnets
- ALB is **internet-facing** with Amazon CloudFront prefix list SG restriction (`pl-82a045eb`):
  - Only Amazon CloudFront IPs can reach the ALB (L3/L4)
  - AWS WAF validates `X-Verify-Origin` custom header (L7)
  - HTTPS-only origin protocol
- Traffic path: Internet -> Amazon CloudFront -> ALB (internet-facing, CF-only SG) -> Pod
- 2 NAT Gateways (HA) for outbound internet
- VPC Flow Logs enabled (all traffic -> CloudWatch Logs)
- NetworkPolicy per tenant namespace (Helm chart template `networkpolicy.yaml`):

```yaml
# Ingress: any source on service port (ALB health checks + traffic) + same namespace
# Egress whitelist:
#   DNS         -> any namespace, UDP/TCP 53
#   Pod Identity -> 169.254.170.23/32, TCP 80
#   IMDS        -> 169.254.169.254/32, TCP 80
#   HTTPS       -> 0.0.0.0/0 except 10.0.0.0/8, TCP 443
#   Same-ns     -> podSelector: {}
# Everything else: implicit deny
```

The `10.0.0.0/8` exception in HTTPS egress blocks cross-tenant pod traffic over port 443 while allowing external AWS service endpoints.

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `Vpc`, `VpcFlowLog`

**Helm chart template**: `helm/charts/openclaw-platform/templates/networkpolicy.yaml`

---

## Layer 4: Authentication

Controls access before reaching a pod.

### Auth Flow

```
auth-ui (static S3 + CloudFront)
  │
  ├─ Sign Up: Cognito SignUp API → email verification → ConfirmSignUp
  │   └─ PostConfirmation Lambda: provisions tenant (SM secret, Pod Identity,
  │      ApplicationSet element, K8s Secret)
  │
  ├─ Sign In: Cognito InitiateAuth → ID token (contains custom:gateway_token)
  │
  └─ Redirect: /t/{tenant}/#token={gateway_token}
       └─ OpenClaw gateway validates token → grants workspace access
```

### Components

- **Amazon Cognito User Pool**: manages user identity (email + password), email verification, custom attributes (`custom:gateway_token`, `custom:tenant_name`)
- **auth-ui**: custom sign-in/sign-up page (not Amazon Cognito Hosted UI). Calls Amazon Cognito API directly from browser via `AWSCognitoIdentityProviderService` JSON-RPC
- **Gateway token**: static per-tenant secret stored in Secrets Manager (`openclaw/{tenant}/gateway-token`). Fetched by OpenClaw gateway via `exec` SecretRef on startup
- **OpenClaw gateway**: runs in `token` auth mode. Validates the token passed via URL fragment (`#token=xxx`) or session cookie
- **`dangerouslyDisableDeviceAuth: true`**: disables OpenClaw's device pairing flow (normally requires terminal confirmation on first connect). Required for web-only access where no terminal is available

### What Amazon Cognito does NOT do

- **No ALB-level Amazon Cognito auth**: HTTPRoute forwards directly to backend (or KEDA interceptor). ALB does not perform `authenticate-cognito` action on new tenant routes
- **No session persistence**: auth-ui does not store Amazon Cognito tokens in localStorage or cookies. Closing the browser tab requires re-authentication
- **No logout**: auth-ui has no sign-out button and does not call Amazon Cognito `GlobalSignOut`

### Why no ALB Amazon Cognito auth

ALB Amazon Cognito auth uses a 302 redirect flow to Amazon Cognito Hosted UI. This is incompatible with the current auth-ui architecture:
1. auth-ui already authenticates via Amazon Cognito API (user would login twice)
2. ALB 302 redirect strips URL fragments — the `#token=xxx` gateway token would be lost
3. Adding ALB auth requires switching from auth-ui to Amazon Cognito Hosted UI, losing custom UX

### Security properties

| Property | Status | Notes |
|----------|--------|-------|
| User identity verification | ✅ | Amazon Cognito email verification |
| Email domain restriction | ✅ | Pre-signup AWS Lambda allowlist |
| Signup rate limiting | ✅ | 5 per domain per hour |
| Workspace access control | ✅ | Gateway token (static) |
| Token expiry | ❌ | Gateway token never expires |
| Token rotation | ❌ | Token set once at signup, never rotated |
| Session management | ❌ | No persistent session, no logout |
| Cross-tenant URL guessing | Low risk | Token is `secrets.token_urlsafe(32)` = 256-bit entropy |

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `UserPool` (imported)

**Helm chart templates**: `configmap.yaml` (gateway auth config), `httproute.yaml` (HTTPRoute)

---

## Layer 5: Tenant Isolation

Prevents one tenant from accessing another tenant's resources.

- One Kubernetes namespace per tenant (`openclaw-{tenant}`)
- ResourceQuota per namespace: CPU 4 cores, memory 8Gi, max 10 pods
- NetworkPolicy: default-deny + explicit allowlist (see Layer 3)
- IAM ABAC: `aws:PrincipalTag/kubernetes-namespace` must match `secretsmanager:ResourceTag/tenant-namespace`
- Separate ServiceAccount per tenant -> Pod Identity Association -> shared `OpenClawTenantRole` with ABAC tags
- PodDisruptionBudget: `minAvailable: 1`

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `TenantRole` (ABAC policy)

**ApplicationSet**: creates Namespace (managedNamespaceMetadata). PVC and SA are managed by Helm/ArgoCD.

**Helm chart templates**: `resourcequota.yaml`, `networkpolicy.yaml`, `pdb.yaml`

---

## Layer 6: Secrets Management

On-demand secret access without persisting credentials on disk.

- Secrets stored in AWS Secrets Manager: `openclaw/{tenant}/{secret-name}`
- Each secret tagged with `tenant-namespace: openclaw-{tenant}`
- `exec SecretRef` pattern: OpenClaw invokes `fetch-secret.mjs` on demand
- `fetch-secret.mjs` uses Pod Identity -> STS AssumeRole -> GetSecretValue
- ABAC policy is designed to ensure tenant can only read its own secrets
- Credentials are temporary (STS) -- no static keys anywhere

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `SecretsManagerABAC` policy statement

**Helm chart template**: `configmap.yaml` (embeds `fetch-secret.mjs`, deployed via init-setup container)

---

## Layer 7: LLM Access Control

LLM access without API keys, with model-level control.

- Amazon Bedrock accessed via Pod Identity -- zero API keys
- `OpenClawTenantRole` grants `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`
- OpenClaw application-level controls (set in Helm ConfigMap):
  - `tool_policy: deny` -- explicit tool allowlist only
  - `exec: deny` -- no shell execution by default
  - `elevated: disabled` -- no privilege escalation
  - `fs: workspaceOnly` -- filesystem restricted to workspace directory

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `BedrockInvoke`, `BedrockDiscovery`

**Helm chart template**: `configmap.yaml` (tools config)

---

## Layer 8: Cost Control

Prevents runaway LLM costs with per-tenant budgets.

- Daily AWS Lambda (`CostEnforcerFn`) queries CloudWatch Logs Insights for per-namespace Amazon Bedrock token usage
- Budget read from Secrets Manager tag `budget-usd` (default: $100/month)
- Alerts at 80% and 100% budget via SNS

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `CostEnforcerFn`, `CostEnforcerSchedule`

---

## Layer 9: Data Protection

Designed to ensure tenant data survives pod restarts, scale-to-zero, and failures.

- PVC (Amazon EFS) per tenant -- persists across pod restarts, scale-to-zero, and AZ failures
- AWS Backup for Amazon EFS (replaces EBS snapshots)
- Container runs as non-root (UID 1000) with `fsGroup: 1000`
- `runAsNonRoot: true`, `readOnlyRootFilesystem: true`

**Helm chart**: `templates/pvc.yaml` (synced by ArgoCD)

**Helm chart template**: `deployment.yaml` (securityContext)

---

## Layer 10: Audit Trail

Records all Amazon Bedrock API calls for compliance and forensics.

- Dedicated CloudTrail trail (`openclaw-bedrock-audit`) -- Amazon Bedrock events only
- Logs stored in S3: `openclaw-audit-logs-{account}-{region}`
- Athena database + table for SQL queries
- CloudWatch Container Insights for pod-level metrics
- Amazon EKS control plane logging: all 5 types

**Managed by**: AWS CDK (CloudTrail + S3 in `eks-cluster-stack.ts`)

---

## Threat Model

| Attack Vector | Mitigation |
|---------------|------------|
| DDoS | Amazon CloudFront edge caching + AWS WAF rate limiting (2000 req/5min/IP) |
| SQLi / XSS | AWS WAF AWSManagedRulesCommonRuleSet |
| Bot signups | AWS WAF Bot Control (opt-in) + email domain allowlist + rate limiting |
| Unauthenticated access | CF prefix list SG + AWS WAF header + gateway token auth |
| Cross-tenant data access | Namespace isolation + NetworkPolicy + ABAC on Secrets Manager |
| Cross-tenant network | NetworkPolicy blocks 10.0.0.0/8 on egress port 443 |
| API key leakage | Zero API keys -- all access via Pod Identity + STS |
| Secret persistence on disk | exec SecretRef -- fetched on demand, never written |
| Prompt injection -> system access | `exec: deny`, `elevated: disabled`, `fs: workspaceOnly` |
| Runaway LLM costs | Daily cost enforcer AWS Lambda + per-tenant budget + SNS alerts |
| Data loss | PVC persistence (Amazon EFS, multi-AZ) + AWS Backup |
| Privilege escalation | Non-root container, `runAsNonRoot: true`, `readOnlyRootFilesystem: true` |
| Karpenter subnet confusion | EC2NodeClass requires both `internal-elb` AND cluster-owned tags |

### Attack Surface Diagram

```
Internet --> CloudFront --> ALB (internet-facing, CF prefix list SG) --> Pod
   |              |           |                                           |
   |         TLS termination  AWS WAF: origin header verify               NetworkPolicy
   |         Edge caching     + Common Rules + Rate Limit              ABAC
   |                          SG: CF prefix list only                  exec deny
   |                                                                   fs: workspaceOnly
   |
   +-> Cognito --> Pre-signup Lambda --> domain check + rate limit
                   Post-confirm Lambda --> SM + Pod Identity + ApplicationSet element
```

---

## What's NOT Covered

| Gap | Notes |
|-----|-------|
| ALB-level Amazon Cognito auth | Incompatible with auth-ui flow (see Layer 4). Gateway token is the auth boundary |
| Gateway token rotation | Token set once at signup, never rotated. Leaked token = permanent access |
| Session persistence | auth-ui doesn't store tokens. Each page load requires re-authentication |
| Logout | No sign-out button. Closing tab is the only "logout" |
| MFA | Amazon Cognito supports MFA but not enabled |
| SAST/DAST | No static/dynamic security testing in CI |
| Image signing | No Sigstore/Cosign verification |
| Secrets rotation | SM secrets not auto-rotated |
| AWS WAF logging | Sampled requests only, no full logging |
| GuardDuty | No runtime threat detection for Amazon EKS |
| KMS encryption | Amazon EFS encrypted at rest (AWS managed key) |

---

## Production Hardening Recommendations

For production deployments, consider the following enhancements:

### Authentication
1. **Gateway token rotation**: rotate token on each sign-in (update Secrets Manager + K8s Secret + Amazon Cognito attribute in PostConfirmation or a dedicated sign-in AWS Lambda)
2. **Session persistence**: store Amazon Cognito refresh token in secure httpOnly cookie, implement silent token refresh
3. **Logout**: add sign-out button that calls Amazon Cognito `GlobalSignOut` and clears gateway session
4. **MFA**: enable Amazon Cognito MFA (TOTP or SMS) for admin accounts at minimum
5. **JWT-based auth**: if OpenClaw adds JWT validation support, replace static gateway token with Amazon Cognito ID token for time-limited, rotatable auth

### Infrastructure
6. **AWS WAF Bot Control**: enable via `cdk deploy -c enableBotControl=true` (additional AWS WAF charges apply)
7. **AWS WAF logging**: enable full request logging to S3 for forensics
8. **GuardDuty Amazon EKS Runtime Monitoring**: detect container-level threats
9. **KMS CMK**: use customer-managed keys for EBS encryption and Secrets Manager
10. **Secrets rotation**: enable Secrets Manager automatic rotation with a AWS Lambda rotator

---

## Compliance Considerations

### SOC 2 Technical Controls

> **Note**: These tables map technical controls only. They do not constitute compliance certification. Customers must conduct their own compliance assessment with qualified auditors.

| Control Area | Current State | Gap |
|-------------|---------------|-----|
| Access Control | Amazon Cognito + ABAC + Pod Identity | Add MFA for admin accounts |
| Encryption in Transit | TLS everywhere | None |
| Encryption at Rest | EBS default encryption | Consider CMK |
| Logging & Monitoring | CloudTrail + CloudWatch + VPC Flow Logs | Enable AWS WAF logging |
| Change Management | ArgoCD + CI/CD + cdk-nag + npm audit | None |
| Incident Response | SNS alerts + Athena queries | Document runbooks |

### HIPAA Technical Controls

> **Note**: These tables map technical controls only. They do not constitute compliance certification. Customers must conduct their own compliance assessment with qualified auditors.

| Requirement | Current State | Gap |
|-------------|---------------|-----|
| PHI encryption at rest | EBS default encryption | Requires CMK |
| PHI encryption in transit | TLS everywhere | None |
| Access logging | CloudTrail + Container Insights | Need comprehensive PHI access logs |
| BAA | Not in place | Requires AWS BAA |
| Minimum necessary access | ABAC + namespace isolation | None |

> **Note**: HIPAA compliance requires a BAA with AWS and verification that all services used are HIPAA-eligible. This platform provides technical controls but does not constitute HIPAA compliance on its own.

## Shared Responsibility

This platform operates under the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/):

| Responsibility | AWS | Platform (this repo) | Customer |
|---|---|---|---|
| Physical infrastructure | ✅ | | |
| Amazon EKS control plane | ✅ | | |
| Node OS patching | ✅ (managed nodegroup) | | |
| Network isolation (VPC, SG) | | ✅ | |
| Tenant namespace isolation | | ✅ | |
| IAM policies (Pod Identity) | | ✅ | Review |
| Application code security | | | ✅ |
| Data classification | | | ✅ |
| Compliance certification | | | ✅ |
| Incident response | | | ✅ |

