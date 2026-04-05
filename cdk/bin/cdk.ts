#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { EksClusterStack } from '../lib/eks-cluster-stack';

const app = new cdk.App();
new EksClusterStack(app, 'OpenClawEksStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});

// cdk-nag: AWS Solutions checks on every synth
cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
