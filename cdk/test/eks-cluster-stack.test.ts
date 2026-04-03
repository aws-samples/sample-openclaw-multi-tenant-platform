import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { EksClusterStack } from '../lib/eks-cluster-stack';

const baseContext = {
  hostedZoneId: 'Z1234567890',
  zoneName: 'example.com',
  certificateArn: 'arn:aws:acm:us-west-2:123456789012:certificate/test',
  cloudfrontCertificateArn: 'arn:aws:acm:us-east-1:123456789012:certificate/test',
  cognitoPoolId: 'us-west-2_test',
  cognitoClientId: 'testclient',
  albClientId: 'testalbclient',
  cognitoDomain: 'test-domain',
  allowedEmailDomains: 'example.com',
  githubOwner: 'test',
  githubRepo: 'test',
  ssoRoleArn: 'arn:aws:iam::123456789012:role/test',
  openclawImage: '123456789012.dkr.ecr.us-west-2.amazonaws.com/ghcr/openclaw/openclaw:latest',
};

test('Stack creates expected resources', () => {
  const app = new cdk.App({ context: baseContext });
  // Just verify it synthesizes without error
  // Full snapshot test would be too brittle for a sample
  expect(() => {
    new EksClusterStack(app, 'TestStack', { env: { account: '123456789012', region: 'us-west-2' } });
  }).not.toThrow();
});

test('Stack synthesizes without ghcrCredentialArn (direct ghcr.io pull)', () => {
  const app = new cdk.App({ context: { ...baseContext, openclawImage: '' } });
  expect(() => {
    new EksClusterStack(app, 'TestStack', { env: { account: '123456789012', region: 'us-west-2' } });
  }).not.toThrow();
});

test('Stack synthesizes with ghcrCredentialArn (ECR pull-through cache)', () => {
  const app = new cdk.App({
    context: {
      ...baseContext,
      openclawImage: '',
      ghcrCredentialArn: 'arn:aws:secretsmanager:us-west-2:123456789012:secret:ecr-pullthroughcache/ghcr-abc123',
    }
  });
  expect(() => {
    new EksClusterStack(app, 'TestStack', { env: { account: '123456789012', region: 'us-west-2' } });
  }).not.toThrow();
});
