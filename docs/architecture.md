# OpenClaw Platform Architecture

> Domain: `claw.snese.net` | Cluster: `openclaw-cluster` (us-west-2)
> Tenants: alice, bob, carol
> Image: `ghcr.io/openclaw/openclaw:2026.3.24` | Helm: `thepagent/openclaw-helm v1.3.14`

---

## 1. System Overview

```
                          ┌─────────────────────────────────────────────────────────┐
                          │                      AWS (us-west-2)                    │
                          │                                                         │
User ──► Browser ──► Cognito Login ──► ALB (HTTPS, *.claw.snese.net)               │
                                        │                                           │
                                        ▼                                           │
                                  EKS Pod (OpenClaw Gateway, trusted-proxy mode)    │
                                        │                                           │
                          ┌─────────────┼─────────────────┐                         │
                          ▼             ▼                  ▼                         │
                     Bedrock       Secrets Manager    AgentCore Browser              │
                    (LLM, Pod     (exec SecretRef,    (web browsing)                │
                     Identity)     ABAC)                                            │
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
        R53[Route53<br/>claw.snese.net<br/>*.claw.snese.net → ALB]
    end

    subgraph ACM
        Cert[ACM Certificate<br/>*.claw.snese.net]
    end

    subgraph Cognito
        CUP[Cognito User Pool<br/>openclaw-users]
        CUP_Client[App Client<br/>ALB Integration]
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

        NAT[NAT Gateway]
        ALB[ALB<br/>shared IngressGroup<br/>Cognito Auth]

        subgraph EKS["EKS Cluster (openclaw-cluster)"]
            MNG[Managed Node Group<br/>m7i.xlarge]
            KarpenterNodes[Karpenter Nodes<br/>c7i / m7i spot]
        end
    end

    subgraph IAM["IAM Roles"]
        TenantRole[TenantRole<br/>Pod Identity + ABAC<br/>per-tenant secret access]
        EBSCSI[EBS CSI Driver Role]
        KarpRole[Karpenter Role]
        LBCRole[LB Controller Role]
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
    ALB --> EKS
    PubSub1 --- NAT
    NAT --- PrivSub1
    NAT --- PrivSub2
    EKS --> TenantRole
    TenantRole --> SecretsManager
    TenantRole --> Bedrock
    EKS --> AB
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

    subgraph KarpenterNS["karpenter namespace"]
        KarpCtrl[Karpenter Controller]
        NP[NodePool<br/>openclaw-pool]
        EC2NC[EC2NodeClass<br/>openclaw-nodes]
    end

    subgraph NSAlice["openclaw-alice namespace"]
        DepA[Deployment<br/>openclaw-alice]
        PVCA[PVC<br/>gp3 EBS]
        SvcA[Service<br/>ClusterIP:18789]
        IngA[Ingress<br/>alice.claw.snese.net]
        NPA[NetworkPolicy<br/>deny-all + allow-alb]
        RQA[ResourceQuota]
        SAA[ServiceAccount<br/>→ TenantRole-alice]
    end

    subgraph NSBob["openclaw-bob namespace"]
        DepB[Deployment<br/>openclaw-bob]
        PVCB[PVC<br/>gp3 EBS]
        SvcB[Service<br/>ClusterIP:18789]
        IngB[Ingress<br/>bob.claw.snese.net]
        NPB[NetworkPolicy<br/>deny-all + allow-alb]
        RQB[ResourceQuota]
        SAB[ServiceAccount<br/>→ TenantRole-bob]
    end

    subgraph NSCarol["openclaw-carol namespace"]
        DepC[Deployment<br/>openclaw-carol]
        PVCC[PVC<br/>gp3 EBS]
        SvcC[Service<br/>ClusterIP:18789]
        IngC[Ingress<br/>carol.claw.snese.net]
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

    User->>Browser: Navigate to alice.claw.snese.net
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
│    --set ingress.host=<tenant>.claw.snese.net                       │
│                                                                     │
│  Step 4: DNS — No action needed                                     │
│  ──────────────────────────────                                     │
│  Wildcard *.claw.snese.net already points to ALB                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. Security Layers

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
