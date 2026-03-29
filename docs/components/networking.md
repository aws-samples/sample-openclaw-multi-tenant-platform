# Networking

The OpenClaw platform uses a layered network architecture: CloudFront → internal ALB → EKS pods, with WAF protection and per-tenant NetworkPolicy isolation.

All CDK resources are in `cdk/lib/eks-cluster-stack.ts`. The ALB and some CloudFront/Route53 resources are created post-deploy by scripts (see notes below).

## VPC

```typescript
// cdk/lib/eks-cluster-stack.ts — "VPC" section
const vpc = new ec2.Vpc(this, 'Vpc', {
  maxAzs: 2,
  natGateways: 2,
  subnetConfiguration: [
    { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
    { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
  ],
});
```

| Setting | Value | Why |
|---------|-------|-----|
| AZs | 2 | Sufficient for HA; keeps NAT costs down |
| NAT Gateways | 2 (one per AZ) | HA — single NAT would be a SPOF |
| Public subnets | `/24` × 2 | NAT Gateways, ALB public-facing (if needed) |
| Private subnets | `/24` × 2 | EKS nodes, pods, internal ALB |

## Traffic Flow

```
User → CloudFront #1 (root domain) → S3 (auth UI)
User → CloudFront #2 (wildcard)    → VPC Origin → Internal ALB → Pod
```

### CloudFront #1: Auth UI (CDK-managed)

Serves the static auth UI (login, signup, welcome pages) from S3.

```typescript
// cdk/lib/eks-cluster-stack.ts — "CloudFront + WAF" section
const distribution = new cloudfront.CloudFrontWebDistribution(this, 'Distribution', {
  viewerCertificate: cloudfront.ViewerCertificate.fromAcmCertificate(cert, {
    aliases: [domainName],  // root domain, e.g. example.com
  }),
  originConfigs: [{
    s3OriginSource: {
      s3BucketSource: authUiBucket,
      originAccessIdentity: oai,
    },
    behaviors: [{
      isDefaultBehavior: true,
      viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
    }],
  }],
  errorConfigurations: [
    { errorCode: 404, responseCode: 200, responsePagePath: '/index.html' },
    { errorCode: 403, responseCode: 200, responsePagePath: '/index.html' },
  ],
});
```

- S3 origin with OAI (Origin Access Identity) — bucket is not publicly accessible
- SPA routing: 404/403 → `/index.html`
- Certificate must be in `us-east-1` (CloudFront requirement)

### CloudFront #2: Tenant Traffic (script-managed)

Created by `scripts/post-deploy.sh` after the first tenant is provisioned (because the ALB ARN is dynamic).

| Setting | Value |
|---------|-------|
| Alias | `*.example.com` (wildcard) |
| Origin | VPC Origin → internal ALB |
| Protocol | HTTPS only |

**Why VPC Origin?** The ALB is internal (no public IP). CloudFront VPC Origin creates a private connection from CloudFront into the VPC, reaching the ALB without exposing it to the internet. This is a managed feature — no VPN, PrivateLink, or proxy needed.

### Internal ALB

The ALB is **not** created by CDK. It's created dynamically by the AWS Load Balancer Controller when the first Ingress resource is applied.

From `helm/charts/openclaw-platform/values.yaml`:

```yaml
ingress:
  className: alb
  annotations:
    alb.ingress.kubernetes.io/group.name: openclaw-shared
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
```

From `helm/charts/openclaw-platform/templates/ingress.yaml`:

```yaml
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "openclaw-helm.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
```

Key design decisions:
- **`scheme: internal`** — ALB has no public IP. All public traffic goes through CloudFront first, which provides DDoS protection, caching, and geographic distribution.
- **`group.name: openclaw-shared`** — All tenant Ingresses share a single ALB. Each tenant gets a host-based rule (`tenant.example.com`).
- **`target-type: ip`** — Routes directly to pod IPs (no NodePort needed).
- **Cognito auth** — When enabled, the ALB handles OIDC authentication before forwarding to pods.

## WAF

```typescript
// cdk/lib/eks-cluster-stack.ts — "CloudFront + WAF" section
const wafAcl = new wafv2.CfnWebACL(this, 'WafAcl', {
  defaultAction: { allow: {} },
  scope: 'REGIONAL',
  rules: [
    {
      name: 'AWSManagedRulesCommonRuleSet',
      priority: 1,
      overrideAction: { none: {} },
      statement: {
        managedRuleGroupStatement: {
          vendorName: 'AWS',
          name: 'AWSManagedRulesCommonRuleSet',
        },
      },
    },
    {
      name: 'RateLimit',
      priority: 2,
      action: { block: {} },
      statement: {
        rateBasedStatement: { limit: 2000, aggregateKeyType: 'IP' },
      },
    },
  ],
});
```

| Rule | Priority | Action | Description |
|------|----------|--------|-------------|
| AWS Common Rules | 1 | None (use rule defaults) | OWASP Top 10 protections — XSS, SQLi, etc. |
| Rate Limit | 2 | Block | 2000 requests per 5-min window per IP |

- **Scope: REGIONAL** — attached to the ALB (not CloudFront)
- WAF ↔ ALB association is done by `scripts/setup-waf.sh` because the ALB ARN is dynamic

## Route53

Managed by `scripts/post-deploy.sh`:

| Record | Type | Target |
|--------|------|--------|
| `example.com` | A (alias) | CloudFront #1 (auth UI) |
| `*.example.com` | A (alias) | CloudFront #2 (tenant traffic) |

The hosted zone is imported in CDK (not created):

```typescript
const hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, 'HostedZone', {
  hostedZoneId: this.node.tryGetContext('hostedZoneId') || '',
  zoneName: domainName,
});
```

## NetworkPolicy (Per-Tenant)

Each tenant namespace gets a NetworkPolicy that enforces strict isolation.

From `helm/charts/openclaw-platform/templates/networkpolicy.yaml`:

```yaml
spec:
  podSelector: {}          # Applies to ALL pods in the namespace
  policyTypes: [Ingress, Egress]

  ingress:
    - from:
        - podSelector: {}                    # Same namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system   # ALB health checks

  egress:
    - to: [{ namespaceSelector: {} }]        # DNS (UDP+TCP 53)
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]

    - to: [{ ipBlock: { cidr: 169.254.170.23/32 } }]   # EKS Pod Identity Agent
      ports: [{ protocol: TCP, port: 80 }]

    - to: [{ ipBlock: { cidr: 169.254.169.254/32 } }]   # EC2 IMDS
      ports: [{ protocol: TCP, port: 80 }]

    - to:                                    # HTTPS outbound (Bedrock, Secrets Manager, etc.)
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8]             # Block cross-tenant pod traffic
      ports: [{ protocol: TCP, port: 443 }]

    - to: [{ podSelector: {} }]              # Same namespace (any port)
```

### Isolation Model

| Direction | Allowed | Blocked |
|-----------|---------|---------|
| Ingress | Same namespace, kube-system | All other namespaces |
| Egress DNS | Any namespace (port 53) | — |
| Egress HTTPS | Internet (0.0.0.0/0) | VPC CIDR (10.0.0.0/8) — blocks pod-to-pod across namespaces |
| Egress Pod Identity | 169.254.170.23:80 | — |
| Egress IMDS | 169.254.169.254:80 | — |
| Egress same NS | Any port | — |

The `10.0.0.0/8` exclusion in the HTTPS egress rule is the key isolation mechanism: tenant pods can reach AWS services (via HTTPS through NAT) but cannot reach pods in other tenant namespaces.
