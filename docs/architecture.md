# OpenClaw Platform Architecture

> Domain: `your-domain.com` | Cluster: `openclaw-cluster` (us-west-2)
> Tenants: alice, bob, carol
> Image: `ghcr.io/openclaw/openclaw:2026.3.24` | Helm: `thepagent/openclaw-helm v1.3.14`

---

## 1. System Overview

```
                          ┌─────────────────────────────────────────────────────────┐
                          │                      AWS (us-west-2)                    │
                          │                                                         │
User ──► Browser ──► Cognito ──┬──► ALB (HTTPS, *.your-domain.com)                  │
                          │    │                │                                    │
                          │    │                ▼                                    │
                          │    │          EKS Pod (OpenClaw Gateway, trusted-proxy)  │
                          │    │                │                                    │
                          │    │    ┌───────────┼─────────────────┐                  │
                          │    │    ▼           ▼                 ▼                  │
                          │    │ Bedrock    Secrets Manager  AgentCore Browser       │
                          │    │(LLM, Pod  (exec SecretRef,  (web browsing)         │
                          │    │ Identity)  ABAC)                                   │
                          │    │                ▲                                    │
                          │    │  Lambda Triggers                                   │
                          │    ├──► Pre-signup ──► validate email domain             │
                          │    └──► Post-confirmation ──► SM + Pod Identity + Helm  │
                          │                                                         │
                          │    S3 ErrorPagesBucket ──► signup error pages            │
                          │                                                         │
                          │    CloudWatch Container Insights ◄── EKS metrics/logs   │
                          │                    │                                     │
                          │               SNS Topic ──► Alarm notifications          │
                          └─────────────────────────────────────────────────────────┘
```

---

## 2. AWS Architecture

```mermaid
graph TB
    subgraph Internet
        User([User / Browser])
    end

    subgraph Route53
        R53[Route53<br/>your-domain.com<br/>*.your-domain.com → ALB]
    end

    subgraph ACM
        Cert[ACM Certificate<br/>*.your-domain.com]
    end

    subgraph Cognito
        CUP[Cognito User Pool<br/>openclaw-users]
        CUP_Client[App Client<br/>ALB Integration]
    end

    subgraph LambdaTriggers["Lambda Triggers"]
        PreSignupFn[Pre-signup Lambda<br/>email domain validation]
        PostConfirmFn[Post-confirmation Lambda<br/>tenant provisioning]
    end

    subgraph S3
        ErrorPages[S3 ErrorPagesBucket<br/>signup error pages]
    end

    subgraph VPC["VPC (10.0.0.0/16)"]
        subgraph AZ1["AZ-a"]
            PubSub1[Public Subnet<br/>10.0.0.0/20]
            PrivSub1[Private Subnet<br/>10.0.128.0/20]
        end
        subgraph AZ2["AZ-b"]
            PubSub2[Public Subnet<br/>10.0.16.0/20]
            PrivSub2[Private Subnet<br/>10.0.144.0/20]
        end

        NAT1[NAT Gateway<br/>AZ-a]
        NAT2[NAT Gateway<br/>AZ-b]
        ALB[ALB<br/>shared IngressGroup<br/>Cognito Auth]

        subgraph EKS["EKS Cluster (openclaw-cluster)"]
            MNG[Managed Node Group<br/>t4g.medium Graviton]
            KarpenterNodes[Karpenter Nodes<br/>arm64 spot]
            KEDA[KEDA<br/>scale-to-zero<br/>optional, disabled by default]
        end
    end

    subgraph CloudWatch
        CWInsights[Container Insights<br/>metrics + logs]
        CWAlarm[CloudWatch Alarm<br/>pod restart count]
    end

    subgraph SNS
        SNSTopic[SNS Topic<br/>alarm notifications]
    end

    subgraph IAM["IAM Roles"]
        TenantRole[TenantRole<br/>Pod Identity + ABAC<br/>per-tenant secret access]
        EBSCSI[EBS CSI Driver Role]
        KarpRole[Karpenter Role]
        LBCRole[LB Controller Role]
        EBSSnapRole[EBS Snapshot Role<br/>PVC backup CronJob]
    end

    subgraph SecretsManager["Secrets Manager"]
        SecAlice[openclaw/alice/*<br/>tag: tenant=alice]
        SecBob[openclaw/bob/*<br/>tag: tenant=bob]
        SecCarol[openclaw/carol/*<br/>tag: tenant=carol]
    end

    subgraph Bedrock
        FM[Foundation Models<br/>Opus 4.6 / Sonnet 4.6<br/>DeepSeek V3.2 / GPT-OSS 120B<br/>Qwen3 Coder 480B / Kimi K2 Thinking]
        IP[Inference Profiles]
    end

    subgraph AgentCore["AgentCore"]
        AB[AgentCore Browser<br/>web browsing]
    end

    User --> R53
    R53 --> ALB
    Cert -.-> ALB
    ALB --> CUP
    CUP --> CUP_Client
    CUP --> PreSignupFn
    CUP --> PostConfirmFn
    PostConfirmFn --> SecretsManager
    PostConfirmFn --> EKS
    ALB --> EKS
    PubSub1 --- NAT1
    NAT1 --- PrivSub1
    PubSub2 --- NAT2
    NAT2 --- PrivSub2
    EKS --> TenantRole
    TenantRole --> SecretsManager
    TenantRole --> Bedrock
    EKS --> AB
    EKS --> CWInsights
    CWAlarm --> SNSTopic
    MNG --> PrivSub1
    KarpenterNodes --> PrivSub2
    KarpRole -.-> KarpenterNodes
    LBCRole -.-> ALB
    EBSCSI -.-> EKS
```

---

## 3. EKS Cluster Detail

```mermaid
graph TB
    subgraph KubeSystem["kube-system namespace"]
        ALBC[ALB Controller<br/>aws-load-balancer-controller]
        EBSCSI[EBS CSI Driver<br/>ebs-csi-controller]
        PIA[Pod Identity Agent<br/>eks-pod-identity-agent]
        CoreDNS[CoreDNS]
        KubeProxy[kube-proxy]
        VPCCNI[VPC CNI<br/>aws-node]
    end

    subgraph AmazonCW["amazon-cloudwatch namespace"]
        CWAgent[CloudWatch Agent<br/>DaemonSet<br/>Container Insights]
    end

    subgraph KarpenterNS["karpenter namespace"]
        KarpCtrl[Karpenter Controller]
        NP[NodePool<br/>openclaw-pool]
        EC2NC[EC2NodeClass<br/>openclaw-nodes]
    end

    subgraph NSAlice["openclaw-alice namespace"]
        DepA[Deployment<br/>openclaw-alice]
        PVCA[PVC<br/>gp3 EBS]
        SvcA[Service<br/>ClusterIP:18789]
        IngA[Ingress<br/>alice.your-domain.com]
        NPA[NetworkPolicy<br/>deny-all + allow-alb]
        RQA[ResourceQuota]
        SAA[ServiceAccount<br/>→ TenantRole-alice]
    end

    subgraph NSBob["openclaw-bob namespace"]
        DepB[Deployment<br/>openclaw-bob]
        PVCB[PVC<br/>gp3 EBS]
        SvcB[Service<br/>ClusterIP:18789]
        IngB[Ingress<br/>bob.your-domain.com]
        NPB[NetworkPolicy<br/>deny-all + allow-alb]
        RQB[ResourceQuota]
        SAB[ServiceAccount<br/>→ TenantRole-bob]
    end

    subgraph NSCarol["openclaw-carol namespace"]
        DepC[Deployment<br/>openclaw-carol]
        PVCC[PVC<br/>gp3 EBS]
        SvcC[Service<br/>ClusterIP:18789]
        IngC[Ingress<br/>carol.your-domain.com]
        NPC[NetworkPolicy<br/>deny-all + allow-alb]
        RQC[ResourceQuota]
        SAC[ServiceAccount<br/>→ TenantRole-carol]
    end

    DepA --> PVCA
    DepA --> SvcA
    SvcA --> IngA
    DepB --> PVCB
    DepB --> SvcB
    SvcB --> IngB
    DepC --> PVCC
    DepC --> SvcC
    SvcC --> IngC
```

---

## 4. OpenClaw Pod Detail

```mermaid
graph LR
    subgraph InitContainers["Init Containers (sequential)"]
        direction TB
        IC1["1. init-config<br/>copy openclaw.json<br/>if not exists on PVC"]
        IC2["2. init-skills<br/>clawhub install<br/>weather, gog"]
        IC3["3. init-tools<br/>npm install<br/>@aws-sdk/client-secrets-manager<br/>+ copy fetch-secret.mjs"]
        IC1 --> IC2 --> IC3
    end

    subgraph MainContainer["Main Container"]
        Main["openclaw gateway<br/>--bind lan<br/>--port 18789"]
    end

    subgraph Volumes
        PVC["PVC (gp3)<br/>/home/user/.openclaw"]
        SA["ServiceAccount Token<br/>(Pod Identity)"]
    end

    IC3 --> Main
    Main --> PVC
    Main --> SA
```

---

## 5. Authentication Flow

```mermaid
sequenceDiagram
    actor User
    participant Browser
    participant ALB
    participant Cognito
    participant Pod as EKS Pod<br/>(OpenClaw Gateway)

    User->>Browser: Navigate to alice.your-domain.com
    Browser->>ALB: GET /
    ALB->>ALB: Check session cookie

    alt No valid session
        ALB->>Browser: 302 Redirect to Cognito
        Browser->>Cognito: /authorize (login page)
        User->>Cognito: Enter credentials
        Cognito->>Browser: 302 Redirect with auth code
        Browser->>ALB: GET /oauth2/idpresponse?code=xxx
        ALB->>Cognito: Exchange code for tokens
        Cognito-->>ALB: ID token + access token
        ALB->>ALB: Set session cookie (AWSELBAuthSessionCookie)
    end

    ALB->>Pod: Forward request<br/>+ x-amzn-oidc-identity header<br/>+ x-amzn-oidc-data (JWT)
    Pod->>Pod: trusted-proxy mode<br/>extract identity from header
    Pod-->>ALB: Response
    ALB-->>Browser: Response
    Browser-->>User: OpenClaw UI
```

---

## 6. Secrets Flow

```mermaid
sequenceDiagram
    participant Pod as OpenClaw Pod<br/>(openclaw-alice)
    participant Script as fetch-secret.mjs<br/>(exec SecretRef)
    participant PIA as Pod Identity Agent<br/>(DaemonSet)
    participant STS
    participant SM as Secrets Manager

    Pod->>Script: exec SecretRef trigger<br/>(tool needs secret)
    Script->>PIA: Request credentials<br/>(via EKS Pod Identity)
    PIA->>STS: AssumeRole<br/>(TenantRole-alice)
    STS-->>PIA: Temporary credentials
    PIA-->>Script: AWS credentials

    Script->>SM: GetSecretValue<br/>(openclaw/alice/api-key)
    Note over SM: ABAC Policy Check:<br/>aws:PrincipalTag/tenant == alice<br/>aws:ResourceTag/tenant == alice
    SM-->>Script: Secret value
    Script-->>Pod: Return secret to stdout
    Pod->>Pod: Use secret in tool execution
```

---

## 7. Tenant Provisioning Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  create-tenant.sh <tenant-name>                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Step 1: Create Secrets Manager secret                              │
│  ────────────────────────────────────                               │
│  aws secretsmanager create-secret                                   │
│    --name openclaw/<tenant>/config                                  │
│    --tags Key=tenant,Value=<tenant>                                 │
│                                                                     │
│  Step 2: Create Pod Identity Association                            │
│  ────────────────────────────────────────                           │
│  aws eks create-pod-identity-association                            │
│    --cluster-name openclaw-cluster                                  │
│    --namespace openclaw-<tenant>                                    │
│    --service-account openclaw-<tenant>                              │
│    --role-arn arn:aws:iam::role/OpenClawTenantRole                  │
│    --tags tenant=<tenant>                                           │
│                                                                     │
│  Step 3: Helm install                                               │
│  ────────────────────                                               │
│  helm install openclaw-<tenant> thepagent/openclaw-helm             │
│    --version 1.3.14                                                 │
│    --namespace openclaw-<tenant> --create-namespace                 │
│    --set tenant=<tenant>                                            │
│    --set image=ghcr.io/openclaw/openclaw:2026.3.24                  │
│    --set ingress.host=<tenant>.your-domain.com                       │
│                                                                     │
│  Step 4: DNS — No action needed                                     │
│  ──────────────────────────────                                     │
│  Wildcard *.your-domain.com already points to ALB                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. Self-Service Signup Flow

```
User ──► Cognito Hosted UI ──► Pre-signup Lambda
                                    │
                          ┌─────────┴─────────┐
                          ▼                    ▼
                    Email domain OK       Domain rejected
                    (auto-confirm)        (→ S3 error page)
                          │
                          ▼
                    Admin approves user
                    (Cognito confirm)
                          │
                          ▼
                    Post-confirmation Lambda
                          │
                    ┌─────┼──────────────┐
                    ▼     ▼              ▼
                SM secret  Pod Identity   Helm install
                (tenant)   association    (openclaw-<tenant>)
                          │
                          ▼
                    Tenant ready at
                    <tenant>.your-domain.com
```

Lambda source: `cdk/lambda/pre-signup/index.py`, `cdk/lambda/post-confirmation/index.py`
Setup script: `scripts/setup-signup-triggers.sh`

---

## 9. PVC Backup

| Item | Detail |
|------|--------|
| Mechanism | CronJob creates EBS snapshots via AWS API |
| Schedule | Daily |
| Retention | 7 days (older snapshots auto-deleted) |
| IAM | `EBSSnapshotRole` with Pod Identity |
| Config | `scripts/pvc-backup-cronjob.yaml`, `scripts/setup-pvc-backup.sh` |

---

## 10. Security Layers

```
┌──────────────┬──────────────────────────────────────────────────────────────┐
│ Layer        │ Controls                                                     │
├──────────────┼──────────────────────────────────────────────────────────────┤
│ Network      │ • VPC with public/private subnet separation                  │
│              │ • Pods run in private subnets only                           │
│              │ • NAT Gateway for outbound internet                          │
│              │ • NetworkPolicy: default-deny + allow ALB ingress only       │
├──────────────┼──────────────────────────────────────────────────────────────┤
│ Auth         │ • Cognito User Pool with per-tenant user assignment          │
│              │ • ALB authenticates via OIDC before forwarding               │
│              │ • trusted-proxy mode: Pod trusts x-amzn-oidc-identity header │
│              │ • Session cookie (AWSELBAuthSessionCookie) with expiry       │
├──────────────┼──────────────────────────────────────────────────────────────┤
│ IAM          │ • Pod Identity (no static credentials)                       │
│              │ • ABAC: aws:PrincipalTag/tenant must match resource tag      │
│              │ • Per-tenant secret isolation in Secrets Manager              │
│              │ • Separate IAM roles for EBS CSI, Karpenter, LBC            │
├──────────────┼──────────────────────────────────────────────────────────────┤
│ OpenClaw     │ • tool_policy: deny (explicit allowlist only)                │
│              │ • exec: ask (user confirmation required)                     │
│              │ • elevated: disabled (no privilege escalation)               │
│              │ • fs: workspaceOnly (no access outside workspace dir)        │
├──────────────┼──────────────────────────────────────────────────────────────┤
│ Container    │ • Non-root execution (UID 1000)                              │
│              │ • fsGroup set for volume permissions                         │
│              │ • ResourceQuota per namespace (CPU, memory, PVC limits)      │
│              │ • Read-only root filesystem where possible                   │
└──────────────┴──────────────────────────────────────────────────────────────┘
```

---

## 11. Monitoring

| Component | Detail |
|-----------|--------|
| Container Insights | EKS addon `amazon-cloudwatch-observability`; CloudWatch Agent DaemonSet collects node and pod metrics |
| CloudWatch Alarm | Monitors pod restart count; triggers SNS notification when threshold exceeded |
| SNS Topic | Receives alarms; can forward to email, Slack, or PagerDuty |
| KEDA | Scale-to-zero support (optional, disabled by default) |

---

## 12. Known Issues & Workarounds

### @smithy/credential-provider-imds Pod Identity Bug

OpenClaw image bundles `@smithy/credential-provider-imds` 4.2.12 which has a hardcoded
`GREENGRASS_HOSTS` allowlist containing only `localhost` and `127.0.0.1`. EKS Pod Identity
Agent uses `169.254.170.23`, which is rejected by `fromContainerMetadata`.

The SDK credential chain is: `fromHttp` → `fromContainerMetadata` → `fromInstanceMetadata`.
While `fromHttp` supports Pod Identity, installing `@aws-sdk/client-secrets-manager` to the
workspace brings its own `@smithy/credential-provider-imds` which shadows `/app`'s version
via `NODE_PATH`, breaking the entire credential chain.

**Fix**: `init-tools` patches both `/app` and workspace copies of `@smithy/credential-provider-imds`
via `sed` to add `169.254.170.23` to `GREENGRASS_HOSTS`.

Reference: [aws-sdk-js-v3#5709](https://github.com/aws/aws-sdk-js-v3/issues/5709)

### NetworkPolicy Egress Whitelist

```
Egress rules (per tenant namespace):
  ┌──────────────────────────────────────────────────────┐
  │ Allow DNS          → any namespace, UDP/TCP 53       │
  │ Allow Pod Identity → 169.254.170.23/32, TCP 80       │
  │ Allow IMDS         → 169.254.169.254/32, TCP 80      │
  │ Allow HTTPS        → 0.0.0.0/0 except 10.0.0.0/8,   │
  │                      TCP 443 (Bedrock, SM, registry)  │
  │ Allow same-ns      → podSelector: {}                  │
  │ Deny everything else (implicit)                       │
  └──────────────────────────────────────────────────────┘
```

The `10.0.0.0/8` exception in HTTPS egress blocks cross-tenant pod traffic over port 443,
while allowing external AWS service endpoints.

### Karpenter Subnet Selection

EC2NodeClass `subnetSelectorTerms` must include both `kubernetes.io/role/internal-elb: 1`
AND `kubernetes.io/cluster/{cluster-name}: owned` tags. Without the cluster tag, Karpenter
may select subnets from other VPCs (e.g., default VPC) that have the `internal-elb` tag,
causing "Security group and subnet belong to different networks" errors.
