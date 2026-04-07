# Networking

Layered network architecture: Amazon CloudFront -> internet-facing ALB (CF prefix list SG) -> Amazon EKS pods, with AWS WAF protection and per-tenant NetworkPolicy isolation.

## VPC

| Setting | Value | Why |
|---------|-------|-----|
| AZs | 2 | Sufficient for HA; keeps NAT costs down |
| NAT Gateways | 2 (one per AZ) | HA -- single NAT would be a SPOF |
| Public subnets | `/24` x 2 | NAT Gateways, ALB |
| Private subnets | `/24` x 2 | Amazon EKS nodes, pods |

**AWS CDK reference**: `cdk/lib/eks-cluster-stack.ts` -> `Vpc`

## Traffic Flow

```
User -> Amazon CloudFront (root domain) -> S3 (auth UI)
User -> Amazon CloudFront (/t/*)           -> Internet-facing ALB (CF prefix list SG) -> Pod
```

### Amazon CloudFront #1: Auth UI (CDK-managed)

Serves the static auth UI from S3 with OAI. SPA routing: 404/403 -> `/index.html`. Certificate must be in `us-east-1`.

### Tenant Traffic (script-managed via post-deploy.sh)

Created by `scripts/post-deploy.sh` after the first tenant is provisioned (ALB ARN is dynamic).

| Setting | Value |
|---------|-------|
| Path pattern | `/t/*` path pattern |
| Origin | Internet-facing ALB |
| Protocol | HTTPS only |

### Internet-Facing ALB (Gateway API)

The ALB is created by the AWS Load Balancer Controller when the Gateway resource is applied. Defined in `helm/gateway.yaml`:

```yaml
apiVersion: gateway.k8s.aws/v1beta1
kind: LoadBalancerConfiguration
spec:
  scheme: internet-facing
  securityGroupPrefixes:
    - "pl-82a045eb"    # Amazon CloudFront managed prefix list
  manageBackendSecurityGroupRules: true
```

Key design decisions:
- **`scheme: internet-facing`** -- ALB is public but restricted to Amazon CloudFront IPs only via the CF managed prefix list (`pl-82a045eb`)
- **Gateway API** -- uses `Gateway` + `HTTPRoute` (not Ingress) for path-based routing (`/t/{tenant}/`)
- **`target-type: ip`** -- routes directly to pod IPs via TargetGroupConfiguration

### 3-Layer Origin Protection

| Layer | Mechanism |
|-------|-----------|
| L3/L4 | ALB Security Group allows only Amazon CloudFront managed prefix list |
| L7 | AWS WAF validates `X-Verify-Origin` custom header from Amazon CloudFront |
| Transport | HTTPS-only origin protocol |

## AWS WAF

| Rule | Priority | Action | Description |
|------|----------|--------|-------------|
| AWS Common Rules | 1 | None (use rule defaults) | OWASP Top 10 -- XSS, SQLi, etc. |
| Rate Limit | 2 | Block | 2000 requests per 5-min window per IP |

- **Scope: REGIONAL** -- attached to the ALB
- AWS WAF <-> ALB association done by `scripts/post-deploy.sh` (dynamic ALB ARN)

## Route53

Managed by `scripts/post-deploy.sh`:

| Record | Type | Target |
|--------|------|--------|
| `example.com` | A (alias) | Amazon CloudFront #1 (auth UI) |
| `example.com` | A (alias) | Amazon CloudFront (auth UI + tenant traffic) |

## NetworkPolicy (Per-Tenant)

Each tenant namespace gets a NetworkPolicy via the Helm chart template (`networkpolicy.yaml`):

```yaml
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]

  ingress:
    # ALB health checks and traffic (IP target type -- traffic comes from VPC CIDR)
    - ports:
        - protocol: TCP
          port: 18789
    # Same namespace
    - from:
        - podSelector: {}

  egress:
    # DNS
    - to: [{ namespaceSelector: {} }]
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    # Amazon EKS Pod Identity Agent
    - to: [{ ipBlock: { cidr: 169.254.170.23/32 } }]
      ports: [{ protocol: TCP, port: 80 }]
    # EC2 IMDS
    - to: [{ ipBlock: { cidr: 169.254.169.254/32 } }]
      ports: [{ protocol: TCP, port: 80 }]
    # HTTPS outbound (Amazon Bedrock, Secrets Manager, etc.)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8]    # Block cross-tenant pod traffic
      ports: [{ protocol: TCP, port: 443 }]
    # Same namespace (any port)
    - to: [{ podSelector: {} }]
```

### Isolation Model

| Direction | Allowed | Blocked |
|-----------|---------|---------|
| Ingress | Service port from any source (ALB), same namespace | All other |
| Egress DNS | Any namespace (port 53) | -- |
| Egress HTTPS | Internet (0.0.0.0/0) | VPC CIDR (10.0.0.0/8) -- blocks cross-namespace pod traffic |
| Egress Pod Identity | 169.254.170.23:80 | -- |
| Egress IMDS | 169.254.169.254:80 | -- |
| Egress same NS | Any port | -- |

## Gateway API Resources

| Resource | Location | Purpose |
|----------|----------|---------|
| GatewayClass | `helm/gateway.yaml` | Registers `gateway.k8s.aws/alb` controller |
| LoadBalancerConfiguration | `helm/gateway.yaml` | Internet-facing ALB + CF prefix list SG |
| Gateway | `helm/gateway.yaml` | HTTPS listener on `claw.{domain}` |
| HTTPRoute | Helm template `httproute.yaml` | Per-tenant path-based routing (`/t/{tenant}/`) |
| TargetGroupConfiguration | Helm template `targetgroupconfig.yaml` | Health check config per tenant |
