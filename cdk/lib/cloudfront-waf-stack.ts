import * as cdk from 'aws-cdk-lib';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import { Construct } from 'constructs';

/**
 * CloudFront WAF stack — must be deployed in us-east-1.
 * Creates a WAF WebACL with CLOUDFRONT scope for edge protection.
 * The WAF ARN is exported as a cross-region reference for the main stack.
 */
export class CloudFrontWafStack extends cdk.Stack {
  public readonly webAclArn: string;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const enableBotControl = this.node.tryGetContext('enableBotControl') === true;

    const rules: wafv2.CfnWebACL.RuleProperty[] = [
      {
        name: 'AWSManagedRulesCommonRuleSet',
        priority: 1,
        overrideAction: { none: {} },
        statement: {
          managedRuleGroupStatement: {
            vendorName: 'AWS',
            name: 'AWSManagedRulesCommonRuleSet',
          },
        },
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: 'CommonRuleSet',
          sampledRequestsEnabled: true,
        },
      },
      {
        name: 'RateLimit',
        priority: 2,
        action: { block: {} },
        statement: {
          rateBasedStatement: {
            limit: 2000,
            aggregateKeyType: 'IP',
          },
        },
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: 'RateLimit',
          sampledRequestsEnabled: true,
        },
      },
    ];

    if (enableBotControl) {
      rules.push({
        name: 'AWSManagedRulesBotControlRuleSet',
        priority: 3,
        overrideAction: { none: {} },
        statement: {
          managedRuleGroupStatement: {
            vendorName: 'AWS',
            name: 'AWSManagedRulesBotControlRuleSet',
          },
        },
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: 'BotControl',
          sampledRequestsEnabled: true,
        },
      });
    }

    const webAcl = new wafv2.CfnWebACL(this, 'CloudFrontWaf', {
      defaultAction: { allow: {} },
      scope: 'CLOUDFRONT',
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: 'OpenClawCloudFrontWaf',
        sampledRequestsEnabled: true,
      },
      rules,
    });

    this.webAclArn = webAcl.attrArn;

    new cdk.CfnOutput(this, 'CloudFrontWafAclArn', { value: webAcl.attrArn });
  }
}
