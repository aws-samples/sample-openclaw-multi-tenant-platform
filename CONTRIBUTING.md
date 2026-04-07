# Contributing

Thank you for your interest in contributing to OpenClaw Platform!

## Prerequisites

- AWS account with admin access
- AWS CLI v2 configured
- Node.js 22+ and npm
- kubectl
- Helm 3
- Python 3.12+
- Docker (for AWS CDK asset bundling)

## Quick Setup

```bash
git clone https://github.com/snese/sample-openclaw-multi-tenant-platform.git
cd sample-openclaw-multi-tenant-platform

# AWS CDK dependencies
cd cdk && npm install && cd ..

# Copy and fill in your values
cp cdk/cdk.json.example cdk/cdk.json
# Edit cdk/cdk.json with your AWS account details
```

## Platform Build

The Platform uses ArgoCD ApplicationSet for multi-tenant management. No Operator build needed.

```

## Project Structure

```
cdk/                    # AWS CDK infrastructure (TypeScript)
  lib/eks-cluster-stack.ts   # Main stack (~700 lines)
  lambda/                    # Amazon Cognito trigger functions + cost enforcement (Python)
  cdk.json.example           # Configuration template
helm/                   # Helm chart (source of truth, synced by ArgoCD)
  charts/openclaw-platform/  # Tenant K8s resources (Deployment, Service, ConfigMap, etc.)
  tenants/values-template.yaml  # Per-tenant values template
auth-ui/                # Auth UI pages (index.html, admin.html, terms, privacy, manifest.json)
scripts/                # Operational scripts (Bash)
docs/                   # Architecture and operations docs
```

## Development Workflow

### 1. Make your changes

See [AGENTS.md](AGENTS.md) for file relationships and how each component works.

### 2. Validate locally

```bash
# AWS CDK
cd cdk && npx tsc --noEmit && npx jest

# Platform

# AWS Lambda
python3 -m pytest cdk/lambda/pre-signup/test_index.py -v
python3 -m pytest cdk/lambda/post-confirmation/test_index.py -v
python3 -m pytest cdk/lambda/cost-enforcer/test_index.py -v

# Helm
helm lint helm/charts/openclaw-platform/

# Sensitive data scan
grep -rn 'AKIA[A-Z0-9]\{16\}' \
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
# AWS CDK matches stack
cd cdk && npx cdk diff  # Should show "no differences"

# Signup flow
# Open https://<your-domain> -> Sign Up -> Workspace loads at claw.<domain>/t/<tenant>/
```

## Configuration

All deployment-specific values live in `cdk/cdk.json` (gitignored). See `cdk/cdk.json.example` for the full list.

## Coding Standards

- **Language**: All code, comments, documentation, issue titles, PR titles, and issue/PR bodies in English
- **Issues**: English, imperative verb start, descriptive (e.g., "Add signup rate limit to pre-signup AWS Lambda")
- **PR titles**: English, conventional commit prefix: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`
- **AWS CDK**: TypeScript, follow existing patterns in `eks-cluster-stack.ts`
- **AWS Lambda**: Python 3.12, boto3, handle errors with `ClientError`
- **Scripts**: Bash, `set -euo pipefail`, use `get_output()` for CloudFormation outputs
- **Commits**: Imperative mood, prefixed: `feat:`, `fix:`, `docs:`, `perf:`, `chore:`

## CI Checks

The GitHub Actions CI pipeline (`.github/workflows/ci.yml`) runs:

3. **Platform**: CDK compile + synth with cdk-nag, Helm lint, Python syntax, Shell syntax, ShellCheck
4. **Security**: hardcoded secrets scan, CJK character scan, commit message sensitive data scan, `npm audit`, Semgrep, Trivy
5. **Main-only**: Docker smoke test (build image + verify binary starts)

### Supply Chain Hardening

All GitHub Actions are **pinned to commit SHA** (not version tags). npm dependencies installed with `--ignore-scripts` in CI security jobs.

All PR checks must pass before merge.

## Architecture Decisions

Key design decisions documented in:

- `docs/architecture.md` -- System overview, ApplicationSet + ArgoCD flow
- `docs/security.md` -- Security model (10 layers)
- `docs/components/` -- Per-component deep dives

## Getting Help

- Open an issue for bugs or feature requests
- Check `docs/operations/admin-guide.md` for operational procedures

## License

MIT-0 -- see [LICENSE](LICENSE).
