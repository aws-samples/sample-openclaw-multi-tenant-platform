# Terraform Alternative Design

> Status: **Design Document** — not yet implemented.

## Overview

Evaluate migrating the OpenClaw platform infrastructure from AWS CDK (TypeScript) to Terraform (HCL). This document maps the current CDK stack structure to Terraform modules, highlights key differences, and outlines a migration path.

## Current CDK Stack Structure

```
cdk/
├── bin/app.ts                    # Entry point
├── lib/
│   ├── network-stack.ts          # VPC, subnets, NAT
│   ├── eks-stack.ts              # EKS cluster, node groups, add-ons
│   ├── auth-stack.ts             # Cognito, Lambda triggers
│   ├── cdn-stack.ts              # CloudFront distributions, S3 origins
│   ├── monitoring-stack.ts       # CloudWatch, SNS, alarms
│   └── tenant-stack.ts           # Per-tenant resources (Secrets, Pod Identity)
```

## Terraform Module Mapping

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
├── modules/
│   ├── network/                  # ← network-stack.ts
│   │   ├── main.tf               #    VPC, subnets, NAT gateway
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── eks/                      # ← eks-stack.ts
│   │   ├── main.tf               #    EKS cluster, managed node groups
│   │   ├── addons.tf             #    EBS CSI, CoreDNS, kube-proxy
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── auth/                     # ← auth-stack.ts
│   │   ├── main.tf               #    Cognito user pool, client, domain
│   │   ├── lambdas.tf            #    Pre-signup, post-confirmation triggers
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── cdn/                      # ← cdn-stack.ts
│   │   ├── main.tf               #    CloudFront, S3, WAF association
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── monitoring/               # ← monitoring-stack.ts
│   │   ├── main.tf               #    CloudWatch Container Insights, alarms
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── tenant/                   # ← tenant-stack.ts
│       ├── main.tf               #    Secrets Manager, Pod Identity association
│       ├── variables.tf
│       └── outputs.tf
├── environments/
│   ├── prod/
│   │   ├── main.tf               #    Module composition for prod
│   │   ├── terraform.tfvars
│   │   └── backend.tf            #    S3 + DynamoDB state backend
│   └── staging/
│       ├── main.tf
│       ├── terraform.tfvars
│       └── backend.tf
```

## Key Differences: CDK vs Terraform

| Aspect | CDK (TypeScript) | Terraform (HCL) |
|--------|-------------------|------------------|
| Language | TypeScript — full programming language | HCL — declarative DSL |
| Abstraction | L2 constructs bundle multiple resources with sane defaults | Resources are 1:1 with AWS API; modules provide grouping |
| State | CloudFormation manages state | Terraform state file (S3 + DynamoDB lock) |
| Drift detection | CloudFormation drift detection (limited) | `terraform plan` shows full diff |
| Preview | `cdk diff` | `terraform plan` |
| Deploy | `cdk deploy` (via CloudFormation) | `terraform apply` |
| Rollback | CloudFormation automatic rollback | Manual — no built-in rollback |
| Multi-provider | AWS only (without custom constructs) | Native multi-provider support |
| Learning curve | Requires TypeScript + CDK concepts | HCL is simpler but less flexible |

### CDK L2 Constructs → Terraform Equivalents

| CDK L2 Construct | What It Does | Terraform Equivalent |
|------------------|-------------|---------------------|
| `ec2.Vpc()` | VPC + subnets + NAT + route tables + IGW | `aws_vpc` + `aws_subnet` + `aws_nat_gateway` + `aws_route_table` + `aws_internet_gateway` (5+ resources) |
| `eks.Cluster()` | EKS + OIDC provider + node groups + IAM roles | `aws_eks_cluster` + `aws_eks_node_group` + `aws_iam_role` + `aws_iam_openid_connect_provider` (4+ resources) |
| `cognito.UserPool()` | User pool + password policy + MFA + email config | `aws_cognito_user_pool` (1 resource, but verbose config) |
| `cloudfront.Distribution()` | Distribution + OAC + cache policy + response headers | `aws_cloudfront_distribution` + `aws_cloudfront_origin_access_control` (2+ resources) |

**Key takeaway**: CDK L2 constructs hide 3-5× more underlying resources. Terraform requires explicit declaration of each, which is more verbose but more transparent.

## Migration Path

### Phase 1: State Import (Parallel Operation)

1. Write Terraform modules that match the existing CDK-deployed resources
2. Use `terraform import` to import existing resources into Terraform state
3. Run `terraform plan` — target zero diff (no changes)
4. Both CDK and Terraform point at the same resources; CDK is read-only at this point

```bash
# Example: import the VPC
terraform import module.network.aws_vpc.main vpc-0abc123def456

# Example: import the EKS cluster
terraform import module.eks.aws_eks_cluster.main openclaw-cluster
```

### Phase 2: Validate and Cut Over

1. Make a small, non-destructive change via Terraform (e.g., add a tag)
2. Verify the change applies cleanly
3. Remove the CDK stack's CloudFormation stack **without deleting resources**:
   ```bash
   # Retain all resources, only delete the CloudFormation stack
   aws cloudformation delete-stack --stack-name Openclaw-* --retain-resources <all-logical-ids>
   ```
4. Terraform is now the sole IaC owner

### Phase 3: Cleanup

1. Remove CDK code from the repository
2. Set up Terraform CI/CD (e.g., GitHub Actions with `terraform plan` on PR, `terraform apply` on merge)
3. Document the new workflow

## Recommended Community Modules

| Module | Purpose |
|--------|---------|
| [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) | VPC with opinionated defaults (similar to CDK L2) |
| [terraform-aws-modules/eks](https://github.com/terraform-aws-modules/terraform-aws-eks) | EKS cluster + managed node groups |
| [terraform-aws-modules/cloudfront](https://github.com/terraform-aws-modules/terraform-aws-cloudfront) | CloudFront distribution |

These community modules reduce the verbosity gap with CDK L2 constructs significantly.

## Trade-offs

| Factor | Stay with CDK | Move to Terraform |
|--------|--------------|-------------------|
| Team familiarity | Already using CDK | Learning curve for HCL |
| Multi-cloud | Not needed today | Future-proofs if needed |
| Ecosystem | Smaller community | Larger module ecosystem |
| State management | CloudFormation (managed) | Self-managed (S3 + DynamoDB) |
| Rollback | Automatic | Manual |
| Transparency | Abstractions hide details | Every resource explicit |

## Open Questions

1. Is multi-cloud a realistic future requirement, or is this AWS-only for the foreseeable future?
2. Who will maintain the Terraform code — is the team comfortable with HCL?
3. Should we use Terragrunt for DRY environment configuration, or keep it simple with tfvars?
4. State backend — shared S3 bucket, or Terraform Cloud / Spacelift?
