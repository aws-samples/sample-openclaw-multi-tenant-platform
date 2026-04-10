#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { EksClusterStack } from '../lib/eks-cluster-stack';
import { CloudFrontWafStack } from '../lib/cloudfront-waf-stack';

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION;

// CloudFront WAF must be in us-east-1 (AWS requirement for CLOUDFRONT scope)
const wafStack = new CloudFrontWafStack(app, 'OpenClawWafStack', {
  env: { account, region: 'us-east-1' },
  crossRegionReferences: true,
});

const eksStack = new EksClusterStack(app, 'OpenClawEksStack', {
  env: { account, region },
  crossRegionReferences: true,
  cloudFrontWafAclArn: wafStack.webAclArn,
});
eksStack.addDependency(wafStack);

// cdk-nag: AWS Solutions checks on every synth
// cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
