# Architecture Decision Records

Key design decisions and their rationale.

---

## ADR-001: Gateway API over Ingress

**Decision**: Use Kubernetes Gateway API with AWS ALB controller instead of Ingress.

**Context**: Need path-based routing (`/t/{tenant}/`) to per-tenant pods with Cognito auth and KEDA scale-to-zero support.

**Rationale**:
- Gateway API is the successor to Ingress, supported by AWS LBC v2.14+
- Cross-namespace backendRef via ReferenceGrant enables routing to KEDA interceptor in `keda` namespace
- ListenerRuleConfiguration CRD enables Cognito auth actions (not possible with standard Ingress annotations in Gateway API mode)
- TargetGroupConfiguration CRD enables per-service target type control (`ip` vs `instance`)

**Trade-off**: Gateway API is newer, less community documentation. Ingress has more examples but lacks cross-namespace routing.

---

## ADR-002: Operator + ArgoCD + Helm (3-layer model)

**Decision**: ApplicationSet manages 3 resources (Namespace, ArgoCD Application, ReferenceGrant). ArgoCD syncs Helm chart for everything else.

**Context**: Need automated tenant provisioning with GitOps drift detection.

**Rationale**:
- **Single owner principle**: each K8s resource has exactly one manager. Operator owns namespace-level resources, ArgoCD/Helm owns workload resources
- Operator is lightweight (~300 lines Rust) — only creates the "envelope" (namespace + ArgoCD app)
- ArgoCD provides drift detection, self-heal, and audit trail for all workload resources
- Helm chart is the single source of truth for tenant workload configuration

**Alternatives considered**:
- ApplicationSet manages everything: 800+ lines, duplicates Helm logic, no drift detection
- Pure Helm (no Operator): no automated provisioning from Cognito signup flow
- Kustomize: less flexible than Helm for per-tenant value injection

---

## ADR-003: KEDA HTTP Add-on for scale-to-zero

**Decision**: Use KEDA HTTPScaledObject with interceptor proxy for scale-to-zero.

**Context**: Tenant pods are idle most of the time. Scale-to-zero saves cost but requires a mechanism to wake pods on incoming HTTP requests.

**Rationale**:
- KEDA HTTP add-on intercepts traffic, counts requests, and scales the backend deployment
- HTTPRoute points to KEDA interceptor (cross-namespace via ReferenceGrant)
- Interceptor proxies to tenant service after scaling up
- Requires TargetGroupConfiguration in `keda` namespace for ALB controller to use `ip` target type

**Trade-off**: Adds complexity (interceptor in request path, TGC, ReferenceGrant). Alternative: ScaledObject with CloudWatch ALB metrics (simpler but slower scale-up, ~2 min vs ~10s).

---

## ADR-004: exec SecretRef over K8s Secrets for gateway token

**Decision**: OpenClaw gateway fetches token from Secrets Manager at runtime via `exec` SecretRef, not from K8s Secret env var.

**Context**: Each tenant has a gateway token for workspace access control.

**Rationale**:
- Token is never written to disk (fetched on demand, held in memory only)
- Pod Identity + ABAC ensures tenant can only read its own secrets
- Secrets Manager provides audit trail (CloudTrail) for every access
- K8s Secret still exists (created by Lambda) as backup, but gateway prefers SM

**Trade-off**: Slightly slower startup (~500ms for SM API call). But more secure than env var injection.

---

## ADR-005: Custom auth-ui over Cognito Hosted UI

**Decision**: Build custom sign-in/sign-up page instead of using Cognito Hosted UI.

**Context**: Need to integrate signup flow with tenant provisioning and gateway token delivery.

**Rationale**:
- Cognito Hosted UI has ugly URLs (`https://<domain>.auth.<region>.amazoncognito.com/`)
- Cannot customize the post-signup flow (need to poll workspace readiness, pass gateway token via URL fragment)
- Cannot integrate progress indicators during provisioning
- auth-ui calls Cognito API directly from browser (no server-side component needed)

**Trade-off**: More code to maintain. No ALB-level Cognito auth on new tenant routes (see `docs/security.md` Layer 4 for details).

---

## ADR-006: Internet-facing ALB with CloudFront prefix list SG

**Decision**: ALB is internet-facing but restricted to CloudFront IPs only via security group.

**Context**: Need CloudFront for edge caching and WAF, but ALB must be reachable from CloudFront.

**Rationale**:
- Internal ALB cannot be reached by CloudFront (no VPC origin support without additional networking)
- CloudFront prefix list SG (`pl-82a045eb`) restricts ALB to CloudFront IPs at L3/L4
- WAF validates `X-Verify-Origin` custom header at L7
- Combined: only CloudFront can reach ALB, and only with correct header

**Alternative considered**: Internal ALB + VPC origin via PrivateLink. More complex, higher cost, and CloudFront VPC origins have limitations.
