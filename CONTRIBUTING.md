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
- Rust toolchain (only if modifying operator code)

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

The Operator image is pre-built via GitHub Actions and published to GHCR (`ghcr.io/snese/openclaw-tenant-operator`). Customers pull it via ECR pull-through cache -- no local build needed.

If you modify `operator/src/`, the image is automatically rebuilt on push to main. For local development:

```bash
cd operator
cargo build --release
cargo clippy -- -D warnings
cargo test --lib
```

To build and push a custom image to your own ECR:

```bash
bash scripts/build-operator.sh
```

## Project Structure

```
cdk/                    # AWS CDK infrastructure (TypeScript)
  lib/eks-cluster-stack.ts   # Main stack (~700 lines)
  lambda/                    # Cognito trigger functions (Python)
  cdk.json.example           # Configuration template
helm/                   # Helm chart (source of truth, synced by ArgoCD)
  charts/openclaw-platform/  # Tenant K8s resources (Deployment, Service, ConfigMap, etc.)
  tenants/values-template.yaml  # Per-tenant values template
auth-ui/                # Auth UI pages (index.html, admin.html, terms, privacy, manifest.json)
operator/               # Tenant Operator (Rust/kube-rs) -- creates NS/PVC/SA + ArgoCD Application + KEDA HSO
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
# Open https://<your-domain> -> Sign Up -> Workspace loads at claw.<domain>/t/<tenant>/
```

## Configuration

All deployment-specific values live in `cdk/cdk.json` (gitignored). See `cdk/cdk.json.example` for the full list.

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
3. **Platform**: CDK compile + synth with cdk-nag, Helm lint, Python syntax, Shell syntax, ShellCheck
4. **Security**: hardcoded secrets scan, CJK character scan, commit message sensitive data scan, `npm audit`, Semgrep, Trivy
5. **Main-only**: Docker smoke test (build image + verify binary starts)

### Supply Chain Hardening

All GitHub Actions are **pinned to commit SHA** (not version tags). npm dependencies installed with `--ignore-scripts` in CI security jobs.

All PR checks must pass before merge.

## Architecture Decisions

Key design decisions documented in:

- `docs/architecture.md` -- System overview, Operator + ArgoCD flow
- `docs/security.md` -- Security model (10 layers)
- `docs/components/` -- Per-component deep dives

## Getting Help

- Open an issue for bugs or feature requests
- Check `docs/operations/admin-guide.md` for operational procedures

## License

MIT -- see [LICENSE](LICENSE).
