import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';

export class RateLimitTable extends Construct {
  public readonly table: dynamodb.Table;

  constructor(scope: Construct, id: string) {
    super(scope, id);

    // DynamoDB table for optimized pre-signup rate limiting
    this.table = new dynamodb.Table(this, 'SignupRateLimit', {
      // Let CloudFormation generate a unique table name to avoid conflicts
      // across multiple stack deployments in the same account/region.
      partitionKey: {
        name: 'domain_hour',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl',
      pointInTimeRecovery: false,  // Not needed for rate limiting data
      deletionProtection: false,   // Sample code, can be deleted
      removalPolicy: cdk.RemovalPolicy.DESTROY,  // Sample code

      // Tags applied via cdk.Tags.of() after creation
    });

    // Apply tags for cost tracking
    cdk.Tags.of(this.table).add('Component', 'auth');
    cdk.Tags.of(this.table).add('Purpose', 'rate-limiting');

    // Output table name for Lambda environment variable
    new cdk.CfnOutput(this, 'RateLimitTableName', {
      value: this.table.tableName,
      description: 'DynamoDB table name for signup rate limiting',
      exportName: 'OpenClawRateLimitTable',
    });
  }
}