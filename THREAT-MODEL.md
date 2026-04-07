# Threat Model — OpenClaw Multi-Tenant Platform

> Architecture: Amazon EKS + ArgoCD ApplicationSet + Helm + KEDA + Amazon Cognito + Amazon Bedrock
> License: MIT-0 (sample code, not for production use)
> Date: 2026-04-07

## System Overview

Multi-tenant AI assistant platform on Amazon EKS. Each user gets an isolated namespace with a private OpenClaw workspace powered by Amazon Bedrock. Self-service signup via Amazon Cognito, GitOps-managed tenant lifecycle via ArgoCD ApplicationSet.

Traffic path: Internet → Amazon CloudFront (single distribution) → Internet-facing ALB (CF prefix list SG + AWS WAF) → Amazon EKS Pod

## Trust Boundaries

TB1: Internet ←→ Amazon CloudFront    (TLS termination, edge caching)
TB2: Amazon CloudFront ←→ ALB               (CF prefix list SG, AWS WAF origin header verification)
TB3: ALB ←→ Amazon EKS Pod           (Gateway API HTTPRoute, KEDA interceptor)
TB4: Pod ←→ AWS APIs                 (Pod Identity → STS → Amazon Bedrock/Secrets Manager/Amazon S3)
TB5: Tenant namespace ←→ Tenant namespace  (NetworkPolicy, ABAC, namespace isolation)
TB6: Amazon Cognito ←→ Auth UI ←→ Gateway   (Amazon Cognito tokens → gateway token → workspace)
TB7: ArgoCD ←→ Amazon EKS API        (ApplicationSet SSA, auto-sync prune+selfHeal)

## STRIDE Analysis

### Spoofing

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| S1 | Attacker impersonates Amazon CloudFront to reach ALB | TB2 | ALB SG restricted to Amazon CloudFront prefix list (pl-82a045eb). AWS WAF is configured to validate X-Verify-Origin custom header |
| S2 | Attacker guesses gateway token to access workspace | TB6 | Token is secrets.token_urlsafe(32) = 256-bit entropy. Stored in Secrets Manager, fetched on-demand via exec SecretRef |
| S3 | Bot mass signup | TB6 | Pre-signup Lambda: email domain allowlist + 5 signups/domain/hour rate limit. Optional AWS WAF Bot Control |
| S4 | Cross-tenant identity spoofing | TB5 | Pod Identity per tenant → STS session with kubernetes-namespace tag → ABAC on Secrets Manager |

### Tampering

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| T1 | Modify tenant Helm values to escalate privileges | TB7 | ArgoCD auto-sync with selfHeal: true is configured to revert manual changes. ApplicationSet owns namespace metadata |
| T2 | Container filesystem tampering | TB3 | readOnlyRootFilesystem: true, non-root UID 1000, workspace restricted to PVC mount |
| T3 | Tamper with secrets on disk | TB4 | exec SecretRef pattern: secrets fetched on-demand via STS, not persisted to filesystem by default |

### Repudiation

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| R1 | Deny LLM API usage | TB4 | Dedicated CloudTrail trail (openclaw-bedrock-audit) is designed to log all Amazon Bedrock InvokeModel calls per namespace |
| R2 | Deny tenant provisioning actions | TB7 | ArgoCD audit log + CloudTrail for Amazon Cognito/Lambda/Secrets Manager operations |

### Information Disclosure

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| I1 | Cross-tenant data access via Secrets Manager | TB5 | ABAC: aws:PrincipalTag/kubernetes-namespace must match secretsmanager:ResourceTag/tenant-namespace |
| I2 | Cross-tenant network sniffing | TB5 | NetworkPolicy: egress blocks 10.0.0.0/8 on port 443. Default-deny ingress except service port |
| I3 | LLM prompt leaking tenant data | TB4 | Each tenant has isolated Amazon Bedrock session. No shared context across tenants |
| I4 | Gateway token in URL fragment | TB6 | URL fragment (#token=xxx) not sent to server. Low risk but token is static (see Known Gaps) |

### Denial of Service

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| D1 | DDoS on ALB | TB1-TB2 | Amazon CloudFront edge caching + AWS WAF rate limit (2000 req/5min/IP) |
| D2 | Tenant resource exhaustion | TB5 | ResourceQuota per namespace: 4 CPU, 8Gi memory, 10 pods |
| D3 | LLM cost runaway | TB4 | Daily CostEnforcer Lambda: per-tenant budget ($100/mo default), SNS alerts at 80%/100% |
| D4 | KEDA scale storm | TB3 | KEDA HTTP Add-on with configurable scaling window. PDB minAvailable: 1 |

### Elevation of Privilege

| # | Threat | Boundary | Mitigation |
|---|--------|----------|------------|
| E1 | Container breakout | TB3 | Non-root (UID 1000), runAsNonRoot: true, readOnlyRootFilesystem: true, no privileged |
| E2 | OpenClaw shell execution | TB3 | exec: deny, elevated: disabled, tool_policy: deny (explicit allowlist only) |
| E3 | Pod Identity cross-account | TB4 | Shared OpenClawTenantRole with ABAC tags. No cross-account assume-role |
| E4 | ArgoCD privilege escalation | TB7 | ApplicationSet uses SSA (Server-Side Apply). ArgoCD Application scoped to tenant namespace only |

## Known Gaps (Documented, Not Production-Ready)

| Gap | Risk | Documented In |
|-----|------|---------------|
| Gateway token never expires or rotates | Leaked token = permanent access | docs/security.md Layer 4, Production Hardening #1 |
| No session persistence or logout | UX gap, not security critical | docs/security.md Layer 4, Production Hardening #3 |
| No MFA | Lower auth assurance | docs/security.md Production Hardening #4 |
| No SAST/DAST in CI | Relies on Probe + Holmes + cdk-nag | docs/security.md "What's NOT Covered" |
| No image signing | Supply chain risk | docs/security.md "What's NOT Covered" |
| No GuardDuty Amazon EKS Runtime | No runtime threat detection | docs/security.md Production Hardening #8 |
| AWS WAF sampled logging only | Limited forensics | docs/security.md Production Hardening #7 |
| Amazon EFS uses AWS managed key | No CMK | docs/security.md Production Hardening #9 |

All gaps are explicitly documented in docs/security.md with production hardening recommendations.

## Shared Responsibility

This sample deploys AWS managed services. Security is a shared responsibility:
- **AWS responsibility**: Physical infrastructure, managed service availability, hypervisor security
- **Customer responsibility**: IAM configuration, network rules, data encryption choices, application-level security, patching container images, Amazon Cognito user pool settings

Reference: https://aws.amazon.com/compliance/shared-responsibility-model/

## Components Removed Since Previous Review

The Rust-based Tenant Operator (operator/) has been completely removed. Tenant lifecycle is now managed by ArgoCD ApplicationSet (server-side apply) + PostConfirmation Lambda. This eliminates:
- Custom CRD and webhook attack surface
- Rust binary supply chain (Cargo dependencies)
- Operator RBAC with cluster-wide permissions

## Conclusion

This is MIT-0 sample code for experimentation and learning. The README and docs/security.md explicitly state it is not intended for production use. All known security gaps are documented with production hardening recommendations.
