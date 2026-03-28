#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { EksClusterStack } from '../lib/eks-cluster-stack';

const app = new cdk.App();
new EksClusterStack(app, 'OpenClawEksStack', {
  env: { region: 'us-west-2' },
});
