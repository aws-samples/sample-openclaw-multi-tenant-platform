# Contributing

Thank you for your interest in contributing to OpenClaw Platform!

## Prerequisites

- AWS account with admin access
- AWS CLI v2 configured
- Node.js 22+ and npm
- kubectl
- Helm 3
- Python 3.12+
- Docker (for CDK asset bundling)
- Rust toolchain (for operator development)

## Quick Setup

```bash
git clone https://github.com/snese/sample-openclaw-multi-tenant-platform.git
cd sample-openclaw-multi-tenant-platform

# CDK dependencies
cd cdk && npm install && cd ..

# Copy and fill in your values
cp cdk/cdk.json.example cdk/cdk.json
# Edit cdk/cdk.json with your AWS account details
```

## Operator Build

```bash
cd operator
cargo build --release
# For ARM64 (Graviton):
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc cargo build --release --target aarch64-unknown-linux-gnu
```

## Project Structure

```
cdk/                    # AWS CDK infrastructure (TypeScript)
  lib/eks-cluster-stack.ts   # Main stack (~700 lines)
  lambda/                    # Cognito trigger functions (Python)
  cdk.json.example           # Configuration template
helm/                   # Kubernetes manifests (reference templates)
  charts/openclaw-platform/  # Helm chart (reference only, not used by operator)
  tenants/values-template.yaml  # Per-tenant values template
auth-ui/                # Auth UI pages (index.html, admin.html, terms, privacy, manifest.json)
operator/               # Tenant Operator (Rust/kube-rs)
scripts/                # Operational scripts (Bash)
docs/                   # Architecture and operations docs
```

## Development Workflow

### 1. Make your changes

See [AGENTS.md](AGENTS.md) for file relationships and how each component works.

### 2. Validate locally

```bash
# CDK
cd cdk && npx tsc --noEmit

# Lambda
python3 -c "compile(open('cdk/lambda/pre-signup/index.py').read(), 'x', 'exec')"
python3 -c "compile(open('cdk/lambda/post-confirmation/index.py').read(), 'x', 'exec')"

# Sensitive data scan
grep -rn 'AKIA\|amazonaws\.com\|[0-9]\{12\}' \
  --include="*.ts" --include="*.py" --include="*.md" --include="*.sh" --include="*.html" \
  | grep -v node_modules | grep -v cdk.out | grep -v cdk.json
# Must return 0 results
```

### 3. Deploy to your environment

```bash
./setup.sh
# Or step-by-step: see README.md Getting Started
```

### 4. Test

```bash
# CDK matches stack
cd cdk && npx cdk diff  # Should show "no differences"

# Signup flow
# Open https://<your-domain> → Sign Up → Workspace loads at claw.<domain>/t/<tenant>/
```

## Configuration

All deployment-specific values live in `cdk/cdk.json` (gitignored). See `cdk/cdk.json.example` for the full list:

| Key | Description |
|-----|-------------|
| `hostedZoneId` | Route53 hosted zone ID |
| `zoneName` | Domain name (e.g., `claw.example.com`) |
| `certificateArn` | ACM certificate ARN (regional) |
| `cloudfrontCertificateArn` | ACM certificate ARN (us-east-1, for CloudFront) |
| `cognitoPoolId` | Cognito User Pool ID |
| `cognitoClientId` | Cognito public client ID (for auth UI) |
| `cognitoDomain` | Cognito domain prefix |
| `allowedEmailDomains` | Comma-separated allowed email domains |
| `ssoRoleArn` | IAM SSO role ARN for kubectl access |
| `openclawImage` | Container image (e.g., `ghcr.io/openclaw/openclaw:2026.3.24`) |
| `sesFromEmail` | SES sender email for welcome emails |
| `albClientId` | Cognito App Client ID for ALB auth |

## Coding Standards

- **Language**: All code, comments, documentation, issue titles, PR titles, and issue/PR bodies in English
- **Issues**: English, imperative verb start, descriptive (e.g., "Add signup rate limit to pre-signup Lambda")
- **PR titles**: English, conventional commit prefix: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- **CDK**: TypeScript, follow existing patterns in `eks-cluster-stack.ts`
- **Lambda**: Python 3.12, boto3, handle errors with `ClientError`
- **Scripts**: Bash, `set -euo pipefail`, use `get_output()` for CloudFormation outputs
- **Commits**: Imperative mood, prefixed: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`

## CI Checks

The GitHub Actions CI pipeline (`.github/workflows/ci.yml`) runs:

1. **Rust**: format check, clippy, unit tests, CRD generation verify
2. **Rust**: cargo-deny (license + security advisory audit)
3. **Platform**: CDK compile + synth with [cdk-nag](https://github.com/cdklabs/cdk-nag) (AWS Solutions checks), Helm lint, Python syntax, Shell syntax, ShellCheck
4. **Security**: hardcoded secrets scan, CJK character scan, commit message sensitive data scan, `npm audit --audit-level=high`, Semgrep (JS/TS/Python), Trivy config + filesystem scan
5. **Main-only**: K8s integration test (k3d), Docker build

### Supply Chain Hardening

All GitHub Actions are **pinned to commit SHA** (not version tags) to prevent [tag poisoning attacks](https://www.microsoft.com/en-us/security/blog/2026/03/24/detecting-investigating-defending-against-trivy-supply-chain-compromise/). When updating an action version, always pin to the full SHA:

```yaml
# Good
- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

# Bad — vulnerable to tag poisoning
- uses: actions/checkout@v4
```

npm dependencies are installed with `--ignore-scripts` in CI security jobs to prevent postinstall hook attacks.

All PR checks must pass before merge.

## Architecture Decisions

Key design decisions and their rationale are documented in:

- `docs/architecture.md` — System overview
- `docs/security.md` — Security model (10 layers)
- `docs/components/` — Per-component deep dives
- `docs/design/` — Future design proposals

## Getting Help

- Open an issue for bugs or feature requests
- Check `docs/operations/admin-guide.md` for operational procedures
- Check `docs/operations/user-guide.md` for end-user documentation

## License

MIT — see [LICENSE](LICENSE).
