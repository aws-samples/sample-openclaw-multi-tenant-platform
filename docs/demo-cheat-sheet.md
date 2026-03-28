# Demo Cheat Sheet

## Before the Demo

- [ ] Verify `https://your-domain.com` loads (auth UI)
- [ ] Verify `https://alice.your-domain.com` responds (302 = OK, pod scaled to 0)
- [ ] Have AWS Console open: EKS, CloudWatch, Cognito, CloudFront
- [ ] Have a test email ready for live signup demo

---

## Demo Script (15 minutes)

### Act 1: The Problem (2 min)

> "Every company wants to give employees AI assistants. But the options are:
> - ChatGPT Enterprise — $60/user/month, data leaves your network
> - Self-hosted LLM — months of engineering, GPU costs
> - Build your own — 6 months, 3 engineers
>
> What if you could deploy a fully isolated AI assistant for every employee in 20 minutes, on your own AWS account, with zero API keys?"

### Act 2: The Landing Page (1 min)

**Open `https://your-domain.com`**

> "This is the employee-facing portal. Custom branded, on your domain. No AWS URLs visible."

Point out:
- Clean design, company branding
- Sign In / Sign Up tabs
- Password strength meter
- CAPTCHA protection

### Act 3: Live Signup (3 min)

**Click Sign Up → enter test email + password → verify code**

> "The employee signs up with their company email. Only approved domains are allowed. Admin gets notified instantly."

**Show the "Account Created — pending approval" screen**

> "No one gets in without admin approval. Zero trust."

**Switch to Cognito Console → Confirm the user**

> "Admin clicks one button. Behind the scenes:
> - A secret is created in Secrets Manager
> - An IAM role is bound to the user's pod
> - CodeBuild runs Helm install
> - The user gets a welcome email with their URL
>
> All automatic. Two minutes later, they have their own AI assistant."

### Act 4: The AI Assistant (3 min)

**Open `https://alice.your-domain.com` → login**

> "Each user gets their own isolated instance. Their own data, their own conversation history, their own skills."

**Send a message to the assistant**

> "Powered by Amazon Bedrock. Opus, Sonnet, DeepSeek, Qwen — six models available. Zero API keys. The pod authenticates via IAM Pod Identity."

**Show the model selector if available**

### Act 5: Security Deep Dive (2 min)

**Switch to AWS Console — show architecture**

> "Let me show you what's under the hood."

Key points to hit:
- **"The ALB is internal. Not accessible from the internet."** (Show ALB → Scheme: internal)
- **"All traffic goes through CloudFront with WAF."** (Show WAF rules)
- **"Each tenant is in its own namespace with NetworkPolicy."** (Show `kubectl get ns`)
- **"Secrets are fetched on-demand, never stored on disk."** (Explain exec SecretRef)
- **"ABAC: Alice cannot read Bob's secrets."** (Explain Pod Identity tags)

### Act 6: Cost Efficiency (2 min)

> "500 employees doesn't mean 500 pods running 24/7."

**Show KEDA:**
```bash
kubectl get httpscaledobject -A
```

> "Right now, all pods are at zero. Nobody is using them. Zero compute cost.
> When Alice opens her URL, the pod starts in 15-30 seconds.
> When she stops, it scales back to zero.
>
> You pay for what you use, not what you provision."

**Show cost estimate:**

> "3 tenants: ~$190/month infrastructure.
> 100 tenants: ~$300/month. Not $300 per user — total.
> Plus Bedrock usage, which is pay-per-token."

### Act 7: Operations (2 min)

> "Everything is infrastructure as code."

```bash
# One command to deploy
npx cdk deploy

# One command to add a user
./scripts/create-tenant.sh bob --display-name "Bob" --emoji "🚀"

# One command to check health
./scripts/health-check.sh

# GitOps: ArgoCD manages all tenants
# Add a values file → git push → tenant appears
```

> "ArgoCD is an EKS Capability — fully managed by AWS. No Helm charts to maintain."

**Show ArgoCD UI if available**

---

## Killer Slides (if using slides)

| Slide | Content |
|-------|---------|
| 1 | "Your AI, Your Cloud, Your Rules" |
| 2 | Architecture diagram (CloudFront → VPC Origin → Internal ALB → EKS) |
| 3 | Security layers table (7 layers) |
| 4 | Cost comparison: ChatGPT Enterprise vs OpenClaw Platform |
| 5 | "20 minutes from `git clone` to production" |

---

## Objection Handling

| Objection | Response |
|-----------|----------|
| "We already use ChatGPT" | "ChatGPT sends your data to OpenAI servers. This runs entirely in your AWS account. Your data never leaves your VPC." |
| "Is it hard to maintain?" | "ArgoCD manages everything via GitOps. CDK deploys in one command. 20 scripts handle every operation. Daily backups are automatic." |
| "What about cost at scale?" | "KEDA scale-to-zero means you only pay for active users. 500 users with 20% concurrency = ~100 pods. That's ~$300/month infra, not $30,000." |
| "Can we use our own models?" | "Bedrock supports 6+ models out of the box. BYOK (bring your own key) for OpenAI/Anthropic direct is on the roadmap." |
| "What if Bedrock is down?" | "Model fallback chain: Opus → Sonnet → DeepSeek. If one model is unavailable, it automatically tries the next." |
| "How long to deploy?" | "20 minutes for CDK. 5 minutes for post-deploy scripts. First tenant in under 30 minutes." |
| "Is it open source?" | "Built on OpenClaw (MIT license). The platform layer (this repo) is your own — fork it, customize it, own it." |

---

## Quick Commands for Live Demo

```bash
# Show cluster
kubectl get nodes -o wide

# Show tenants (all scaled to 0)
kubectl get httpscaledobject -A

# Show PVCs (data persists)
kubectl get pvc -A -l app.kubernetes.io/name=openclaw-helm

# Show security
kubectl get networkpolicy -A

# Show ALB is internal
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'openclaw')].Scheme"

# Show WAF
aws wafv2 list-web-acls --scope REGIONAL --region us-west-2 --query "WebACLs[].Name"

# Health check
./scripts/health-check.sh

# Create tenant live
./scripts/create-tenant.sh demo-user --display-name "Demo" --emoji "🎯"
```

---

## After the Demo

- Share the repo: `https://github.com/<YOUR_GITHUB_ORG>/openclaw-platform`
- Offer a 30-minute hands-on session to deploy in their account
- Key differentiator: **"Your data, your cloud, your rules. Deploy in 20 minutes."**
