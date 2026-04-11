#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { EksClusterStack } from '../lib/eks-cluster-stack';
import { execSync } from 'child_process';

// Generate dynamic stack name to avoid deployment conflicts
const generateStackName = (): string => {
  const baseName = 'OpenClawEksStack';

  // Use explicit suffix if provided
  if (process.env.CDK_STACK_SUFFIX) {
    return `${baseName}-${process.env.CDK_STACK_SUFFIX}`;
  }

  // Hybrid approach: git hash + timestamp for uniqueness
  try {
    const gitHash = execSync('git rev-parse --short HEAD', {stdio: 'pipe'})
      .toString().trim();
    const timestamp = new Date().toISOString().slice(11, 19).replace(/:/g, '');
    return `${baseName}-${gitHash}-${timestamp}`;
  } catch {
    // Fallback to timestamp-only if git unavailable
    const timestamp = new Date().toISOString()
      .replace(/[:.]/g, '-')
      .slice(0, 19);
    return `${baseName}-${timestamp}`;
  }
};

const app = new cdk.App();
const stackName = generateStackName();

// Export stack name for scripts to discover
console.log(`📋 Using stack name: ${stackName}`);

new EksClusterStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});

// cdk-nag: AWS Solutions checks on every synth
cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
