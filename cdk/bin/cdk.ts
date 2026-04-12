#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { EksClusterStack } from '../lib/eks-cluster-stack';

// Stack name: fixed for idempotent updates (cdk deploy = create or update).
// Use CDK_STACK_SUFFIX for multiple instances in the same account/region.
// Resource-level uniqueness is handled by ${stackName} prefixes in the stack.
const baseName = 'OpenClawEksStack';
const stackName = process.env.CDK_STACK_SUFFIX
  ? `${baseName}-${process.env.CDK_STACK_SUFFIX}`
  : baseName;

const app = new cdk.App();

new EksClusterStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});

// cdk-nag: AWS Solutions checks on every synth
cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
