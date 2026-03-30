import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as events from 'aws-cdk-lib/aws-events';
import * as events_targets from 'aws-cdk-lib/aws-events-targets';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as codebuild from 'aws-cdk-lib/aws-codebuild';
import * as cw_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as sns from 'aws-cdk-lib/aws-sns';
import { KubectlV35Layer } from '@aws-cdk/lambda-layer-kubectl-v35';
import { Construct } from 'constructs';

export class EksClusterStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ── VPC ─────────────────────────────────────────────────────────────────
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 2,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // ── EKS Cluster ─────────────────────────────────────────────────────────
    // VPC Flow Logs — network forensics for all traffic
    new ec2.FlowLog(this, 'VpcFlowLog', {
      resourceType: ec2.FlowLogResourceType.fromVpc(vpc),
      destination: ec2.FlowLogDestination.toCloudWatchLogs(),
      trafficType: ec2.FlowLogTrafficType.ALL,
    });

    const cluster = new eks.Cluster(this, 'Cluster', {
      vpc,
      version: eks.KubernetesVersion.V1_35,
      defaultCapacity: 0,
      clusterName: 'openclaw-cluster',
      authenticationMode: eks.AuthenticationMode.API_AND_CONFIG_MAP,
      kubectlLayer: new KubectlV35Layer(this, 'KubectlLayer'),
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
        eks.ClusterLoggingTypes.CONTROLLER_MANAGER,
        eks.ClusterLoggingTypes.SCHEDULER,
      ],
    });

    // ── Cluster Access: allow deployer's SSO role to use kubectl ─────────
    // Users must set CDK context 'ssoRoleArn' to their SSO role ARN.
    // Example: cdk deploy -c ssoRoleArn=arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/MyRole
    const ssoRoleArn = this.node.tryGetContext('ssoRoleArn');
    if (ssoRoleArn) {
      new eks.CfnAccessEntry(this, 'DeployerAccess', {
        clusterName: cluster.clusterName,
        principalArn: ssoRoleArn,
        type: 'STANDARD',
        accessPolicies: [{
          accessScope: { type: 'cluster' },
          policyArn: 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy',
        }],
      });
    }

    // ── Managed Node Group ──────────────────────────────────────────────────
    cluster.addNodegroupCapacity('SystemNodes', {
      instanceTypes: [new ec2.InstanceType('t4g.medium')],
      amiType: eks.NodegroupAmiType.AL2023_ARM_64_STANDARD,
      minSize: 1,
      maxSize: 5,
      desiredSize: 2,
      nodegroupName: 'system-graviton',
      labels: { role: 'system' },
    });

    // ── EBS CSI Driver (with Pod Identity IAM) ──────────────────────────────
    const ebsCsiRole = new iam.Role(this, 'EbsCsiRole', {
      roleName: `EbsCsiDriverRole-${cluster.clusterName}`,
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonEBSCSIDriverPolicy'),
      ],
    });
    ebsCsiRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      actions: ['sts:TagSession'],
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
    }));

    new eks.CfnAddon(this, 'EbsCsiDriver', {
      clusterName: cluster.clusterName,
      addonName: 'aws-ebs-csi-driver',
      podIdentityAssociations: [{
        roleArn: ebsCsiRole.roleArn,
        serviceAccount: 'ebs-csi-controller-sa',
      }],
    });

    // ── Other EKS Add-ons (no special IAM needed) ───────────────────────────
    for (const addonName of ['eks-pod-identity-agent', 'vpc-cni', 'coredns', 'kube-proxy']) {
      new eks.CfnAddon(this, addonName.replace(/-/g, ''), {
        clusterName: cluster.clusterName,
        addonName,
      });
    }

    // ── CloudWatch Container Insights ─────────────────────────────────────
    const cwObsRole = new iam.Role(this, 'CwObservabilityRole', {
      roleName: `CwObservabilityRole-${cluster.clusterName}`,
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AWSXrayWriteOnlyAccess'),
      ],
    });
    cwObsRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      actions: ['sts:TagSession'],
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
    }));

    new eks.CfnAddon(this, 'CwObservability', {
      clusterName: cluster.clusterName,
      addonName: 'amazon-cloudwatch-observability',
      podIdentityAssociations: [{
        roleArn: cwObsRole.roleArn,
        serviceAccount: 'cloudwatch-agent',
      }],
    });

    // gp3 StorageClass — set as default for tenant PVCs
    cluster.addManifest('Gp3StorageClass', {
      apiVersion: 'storage.k8s.io/v1',
      kind: 'StorageClass',
      metadata: { name: 'gp3' },
      provisioner: 'ebs.csi.aws.com',
      parameters: { type: 'gp3', fsType: 'ext4' },
      reclaimPolicy: 'Delete',
      volumeBindingMode: 'WaitForFirstConsumer',
      allowVolumeExpansion: true,
    });

    // ── AWS Load Balancer Controller ────────────────────────────────────────
    const lbcSa = cluster.addServiceAccount('LbcSa', {
      name: 'aws-load-balancer-controller',
      namespace: 'kube-system',
    });
    lbcSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: [
        // EC2 — read-only discovery
        'ec2:DescribeAccountAttributes', 'ec2:DescribeAddresses', 'ec2:DescribeAvailabilityZones',
        'ec2:DescribeInternetGateways', 'ec2:DescribeVpcs', 'ec2:DescribeVpcPeeringConnections',
        'ec2:DescribeSubnets', 'ec2:DescribeSecurityGroups', 'ec2:DescribeInstances',
        'ec2:DescribeNetworkInterfaces', 'ec2:DescribeTags', 'ec2:DescribeCoipPools',
        'ec2:GetCoipPoolUsage',
        // EC2 — security group management
        'ec2:CreateSecurityGroup', 'ec2:DeleteSecurityGroup',
        'ec2:AuthorizeSecurityGroupIngress', 'ec2:RevokeSecurityGroupIngress',
        'ec2:CreateTags', 'ec2:DeleteTags',
        // ELB — load balancer lifecycle
        'elasticloadbalancing:CreateLoadBalancer', 'elasticloadbalancing:DeleteLoadBalancer',
        'elasticloadbalancing:DescribeLoadBalancers', 'elasticloadbalancing:DescribeLoadBalancerAttributes',
        'elasticloadbalancing:ModifyLoadBalancerAttributes',
        // ELB — target groups
        'elasticloadbalancing:CreateTargetGroup', 'elasticloadbalancing:DeleteTargetGroup',
        'elasticloadbalancing:DescribeTargetGroups', 'elasticloadbalancing:DescribeTargetGroupAttributes',
        'elasticloadbalancing:ModifyTargetGroupAttributes',
        'elasticloadbalancing:RegisterTargets', 'elasticloadbalancing:DeregisterTargets',
        'elasticloadbalancing:DescribeTargetHealth',
        // ELB — listeners & rules
        'elasticloadbalancing:CreateListener', 'elasticloadbalancing:DeleteListener',
        'elasticloadbalancing:DescribeListeners', 'elasticloadbalancing:DescribeListenerCertificates',
        'elasticloadbalancing:DescribeListenerAttributes', 'elasticloadbalancing:ModifyListener',
        'elasticloadbalancing:CreateRule', 'elasticloadbalancing:DeleteRule',
        'elasticloadbalancing:DescribeRules', 'elasticloadbalancing:ModifyRule',
        // ELB — misc
        'elasticloadbalancing:AddTags', 'elasticloadbalancing:RemoveTags',
        'elasticloadbalancing:SetSecurityGroups', 'elasticloadbalancing:SetSubnets',
        'elasticloadbalancing:DescribeSSLPolicies', 'elasticloadbalancing:DescribeTags',
        'acm:ListCertificates', 'acm:DescribeCertificate',
        'iam:ListServerCertificates', 'iam:GetServerCertificate',
        'iam:CreateServiceLinkedRole',
        'cognito-idp:DescribeUserPoolClient',
        'wafv2:GetWebACL', 'wafv2:GetWebACLForResource',
        'wafv2:AssociateWebACL', 'wafv2:DisassociateWebACL',
        'shield:GetSubscriptionState', 'shield:DescribeProtection',
        'shield:CreateProtection', 'shield:DeleteProtection',
      ],
      resources: ['*'],
    }));

    cluster.addHelmChart('LbController', {
      chart: 'aws-load-balancer-controller',
      repository: 'https://aws.github.io/eks-charts',
      namespace: 'kube-system',
      values: {
        clusterName: cluster.clusterName,
        serviceAccount: { create: false, name: 'aws-load-balancer-controller' },
        region: this.region,
        vpcId: vpc.vpcId,
        controllerConfig: { featureGates: { ALBGatewayAPI: true } },
      },
    });

    // ── Karpenter ───────────────────────────────────────────────────────────

    // Node IAM Role
    const karpenterNodeRole = new iam.Role(this, 'KarpenterNodeRole', {
      roleName: `KarpenterNodeRole-${cluster.clusterName}`,
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    new iam.CfnInstanceProfile(this, 'KarpenterInstanceProfile', {
      instanceProfileName: `KarpenterNodeInstanceProfile-${cluster.clusterName}`,
      roles: [karpenterNodeRole.roleName],
    });

    cluster.awsAuth.addRoleMapping(karpenterNodeRole, {
      groups: ['system:bootstrappers', 'system:nodes'],
      username: 'system:node:{{EC2PrivateDNSName}}',
    });

    // Namespace (must exist before SA)
    const karpenterNs = cluster.addManifest('KarpenterNs', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: 'karpenter' },
    });

    // Controller SA
    const karpenterSa = cluster.addServiceAccount('KarpenterSa', {
      name: 'karpenter',
      namespace: 'karpenter',
    });
    karpenterSa.node.addDependency(karpenterNs);

    karpenterSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: [
        'ec2:CreateLaunchTemplate', 'ec2:CreateFleet', 'ec2:RunInstances',
        'ec2:CreateTags', 'ec2:TerminateInstances', 'ec2:DeleteLaunchTemplate',
        'ec2:DescribeLaunchTemplates', 'ec2:DescribeInstances',
        'ec2:DescribeSecurityGroups', 'ec2:DescribeSubnets',
        'ec2:DescribeImages', 'ec2:DescribeInstanceTypes',
        'ec2:DescribeInstanceTypeOfferings', 'ec2:DescribeAvailabilityZones',
        'ec2:DescribeSpotPriceHistory', 'pricing:GetProducts',
        'ssm:GetParameter', 'iam:PassRole',
        'iam:CreateInstanceProfile', 'iam:TagInstanceProfile',
        'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile',
        'iam:DeleteInstanceProfile', 'iam:GetInstanceProfile',
        'eks:DescribeCluster',
        'sqs:DeleteMessage', 'sqs:GetQueueAttributes',
        'sqs:GetQueueUrl', 'sqs:ReceiveMessage',
      ],
      resources: ['*'],
    }));

    // Helm chart
    const karpenterChart = cluster.addHelmChart('Karpenter', {
      chart: 'karpenter',
      repository: 'oci://public.ecr.aws/karpenter/karpenter',
      namespace: 'karpenter',
      createNamespace: false,
      version: '1.3.3',
      values: {
        serviceAccount: { create: false, name: 'karpenter' },
        settings: {
          clusterName: cluster.clusterName,
          clusterEndpoint: cluster.clusterEndpoint,
          interruptionQueue: '',
        },
        controller: {
          resources: {
            requests: { cpu: '1', memory: '1Gi' },
            limits: { cpu: '1', memory: '1Gi' },
          },
        },
      },
    });
    karpenterChart.node.addDependency(karpenterSa);

    // EC2NodeClass — use internal-elb tag for private subnets, cluster SG tag for security groups
    const nodeClass = cluster.addManifest('KarpenterNodeClass', {
      apiVersion: 'karpenter.k8s.aws/v1',
      kind: 'EC2NodeClass',
      metadata: { name: 'default' },
      spec: {
        amiSelectorTerms: [{ alias: 'al2023@latest' }],
        role: karpenterNodeRole.roleName,
        subnetSelectorTerms: [
          { tags: { 'kubernetes.io/role/internal-elb': '1', [`kubernetes.io/cluster/${cluster.clusterName}`]: 'owned' } },
        ],
        securityGroupSelectorTerms: [
          { tags: { [`kubernetes.io/cluster/${cluster.clusterName}`]: 'owned' } },
        ],
      },
    });
    nodeClass.node.addDependency(karpenterChart);

    // NodePool
    const nodePool = cluster.addManifest('KarpenterNodePool', {
      apiVersion: 'karpenter.sh/v1',
      kind: 'NodePool',
      metadata: { name: 'default' },
      spec: {
        template: {
          spec: {
            nodeClassRef: { group: 'karpenter.k8s.aws', kind: 'EC2NodeClass', name: 'default' },
            requirements: [
              { key: 'karpenter.sh/capacity-type', operator: 'In', values: ['on-demand', 'spot'] },
              { key: 'kubernetes.io/arch', operator: 'In', values: ['arm64'] },
              { key: 'karpenter.k8s.aws/instance-category', operator: 'In', values: ['c', 'm', 'r'] },
              { key: 'karpenter.k8s.aws/instance-generation', operator: 'Gt', values: ['2'] },
            ],
          },
        },
        limits: { cpu: '100' },
        disruption: {
          consolidationPolicy: 'WhenEmptyOrUnderutilized',
          consolidateAfter: '1m',
        },
      },
    });
    nodePool.node.addDependency(nodeClass);

    // ── ArgoCD ────────────────────────────────────────────────────────────
    // Managed via EKS Capability (not Helm chart). Created by:
    //   aws eks create-capability --type ARGOCD --cluster-name <cluster>
    // See scripts/setup-argocd.sh and docs/argocd.md for details.
    // EKS Capability provides: fully managed ArgoCD, hosted UI, AWS Identity Center auth.

    // ── Shared Tenant IAM Role ──────────────────────────────────────────────
    const tenantRole = new iam.Role(this, 'TenantRole', {
      roleName: 'OpenClawTenantRole',
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
      description: 'Shared IAM role for all OpenClaw tenant pods (ABAC via EKS Pod Identity)',
    });
    tenantRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      actions: ['sts:TagSession'],
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
    }));

    // Bedrock: invoke — us. inference profiles route cross-region, allow all regions
    tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'BedrockInvoke',
      actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
      resources: [
        'arn:aws:bedrock:*::foundation-model/*',
        `arn:aws:bedrock:*:${this.account}:inference-profile/*`,
      ],
    }));

    // Bedrock: model discovery
    tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'BedrockDiscovery',
      actions: ['bedrock:ListFoundationModels', 'bedrock:ListInferenceProfiles', 'bedrock:GetInferenceProfile'],
      resources: ['*'],
    }));

    // Secrets Manager: ABAC — tenant can only read secrets tagged with its own namespace
    tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'SecretsManagerABAC',
      actions: ['secretsmanager:GetSecretValue'],
      resources: ['*'],
      conditions: {
        StringEquals: {
          'secretsmanager:ResourceTag/tenant-namespace': '${aws:PrincipalTag/kubernetes-namespace}',
        },
      },
    }));

    // AgentCore Browser: session management + automation + profile persistence
    tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'AgentCoreBrowser',
      actions: [
        'bedrock-agentcore:StartBrowserSession',
        'bedrock-agentcore:StopBrowserSession',
        'bedrock-agentcore:GetBrowserSession',
        'bedrock-agentcore:ListBrowserSessions',
        'bedrock-agentcore:ConnectBrowserAutomationStream',
        'bedrock-agentcore:ConnectBrowserLiveViewStream',
        'bedrock-agentcore:GetBrowserProfile',
        'bedrock-agentcore:SaveBrowserSessionProfile',
      ],
      resources: [`arn:aws:bedrock-agentcore:${this.region}:${this.account}:browser/*`],
    }));

    // ── Imported Resources (existing, not managed by this stack) ───────────
    const domainName = this.node.tryGetContext('zoneName') || 'example.com';
    const cognitoPoolId = this.node.tryGetContext('cognitoPoolId') || '';
    const cognitoClientId = this.node.tryGetContext('cognitoClientId') || '';
    const albClientId = this.node.tryGetContext('albClientId') || cognitoClientId;
    const cognitoDomain = this.node.tryGetContext('cognitoDomain') || '';
    const allowedEmailDomains = this.node.tryGetContext('allowedEmailDomains') || 'example.com';
    const githubOwner = this.node.tryGetContext('githubOwner') || '';
    const githubRepo = this.node.tryGetContext('githubRepo') || 'openclaw-platform';

    const hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, 'HostedZone', {
      hostedZoneId: this.node.tryGetContext('hostedZoneId') || '',
      zoneName: domainName,
    });

    const certificate = acm.Certificate.fromCertificateArn(this, 'Certificate',
      this.node.tryGetContext('certificateArn') || '',
    );

    const userPool = cognito.UserPool.fromUserPoolId(this, 'UserPool', cognitoPoolId);

    // ── CloudWatch Alerts ──────────────────────────────────────────────────
    const alertsTopic = new sns.Topic(this, 'AlertsTopic', { topicName: 'OpenClawAlerts' });

    const podRestartAlarm = new cloudwatch.Alarm(this, 'PodRestartAlarm', {
      alarmName: 'OpenClaw-PodRestartCount',
      metric: new cloudwatch.Metric({
        namespace: 'ContainerInsights',
        metricName: 'pod_number_of_container_restarts',
        dimensionsMap: { ClusterName: 'openclaw-cluster' },
        period: cdk.Duration.seconds(300),
        statistic: 'Sum',
      }),
      evaluationPeriods: 1,
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
    });
    podRestartAlarm.addAlarmAction(new cw_actions.SnsAction(alertsTopic));

    // ── S3: Error Pages Bucket ──────────────────────────────────────────────
    const errorPagesBucket = new s3.Bucket(this, 'ErrorPagesBucket', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ── Lambda: Pre-Signup ──────────────────────────────────────────────────
    const preSignupFn = new lambda.Function(this, 'PreSignupFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/pre-signup'),
      environment: { SNS_TOPIC_ARN: alertsTopic.topicArn, ALLOWED_DOMAINS: allowedEmailDomains },
      timeout: cdk.Duration.seconds(10),
    });
    alertsTopic.grantPublish(preSignupFn);

    // ── Lambda: Post-Confirmation ───────────────────────────────────────────
    // Layer removed (#41): Lambda only uses boto3 + stdlib for K8s API calls.
    // requirements.txt exists for local testing; CDK bundles via fromAsset.
    const postConfirmFn = new lambda.Function(this, 'PostConfirmFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/post-confirmation'),
      environment: {
        SNS_TOPIC_ARN: alertsTopic.topicArn,
        CLUSTER_NAME: cluster.clusterName,
        CERTIFICATE_ARN: certificate.certificateArn,
        DOMAIN: domainName,
        CODEBUILD_PROJECT: 'openclaw-tenant-builder',
        OPENCLAW_IMAGE: this.node.tryGetContext('openclawImage') || 'ghcr.io/openclaw/openclaw:latest',
        TENANT_ROLE_ARN: tenantRole.roleArn,
        USER_POOL_ID: cognitoPoolId,
      },
      timeout: cdk.Duration.seconds(60),
    });
    alertsTopic.grantPublish(postConfirmFn);
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:CreateSecret', 'secretsmanager:TagResource', 'secretsmanager:GetSecretValue', 'secretsmanager:RestoreSecret', 'secretsmanager:UpdateSecret'],
      resources: [`arn:aws:secretsmanager:${this.region}:${this.account}:secret:openclaw/*`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:AdminUpdateUserAttributes'],
      resources: [`arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['eks:CreatePodIdentityAssociation', 'eks:DescribeCluster'],
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${cluster.clusterName}`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['codebuild:StartBuild'],
      resources: [`arn:aws:codebuild:${this.region}:${this.account}:project/openclaw-tenant-builder`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['iam:PassRole', 'iam:GetRole'],
      resources: [tenantRole.roleArn],
    }));

    // ── CodeBuild: Tenant Builder ────────────────────────────────────────────
    const tenantBuilder = new codebuild.Project(this, 'TenantBuilder', {
      projectName: 'openclaw-tenant-builder',
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.SMALL,
      },
      environmentVariables: {
        CLUSTER_NAME: { value: cluster.clusterName },
        TENANT_ROLE_ARN: { value: tenantRole.roleArn },
        REGION: { value: this.region },
        CHART_BUCKET: { value: errorPagesBucket.bucketName },
        DOMAIN: { value: domainName },
        CERTIFICATE_ARN: { value: certificate.certificateArn },
        COGNITO_POOL_ID: { value: cognitoPoolId },
        ALB_CLIENT_ID: { value: albClientId },
        COGNITO_DOMAIN: { value: cognitoDomain },
        COGNITO_CLIENT_ID: { value: cognitoClientId },
      },
      buildSpec: codebuild.BuildSpec.fromObject({
        version: '0.2',
        phases: {
          install: {
            commands: [
              'curl -LO https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl && chmod +x kubectl && mv kubectl /usr/local/bin/',
              'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash',
              `aws eks update-kubeconfig --region ${this.region} --name ${cluster.clusterName}`,
            ],
          },
          build: {
            commands: [
              'NAMESPACE="openclaw-${TENANT_NAME}"',
              'RELEASE="openclaw-${TENANT_NAME}"',
              'aws s3 cp s3://${CHART_BUCKET}/provision-tenant.sh /tmp/provision-tenant.sh',
              'bash /tmp/provision-tenant.sh',
            ],
          },
        },
      }),
      source: codebuild.Source.s3({ bucket: errorPagesBucket, path: 'codebuild/source.zip' }),
    });
    errorPagesBucket.grantRead(tenantBuilder.role!);
    tenantBuilder.role!.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:DescribeUserPoolClient', 'cognito-idp:UpdateUserPoolClient'],
      resources: [`arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`],
    }));
    tenantBuilder.role!.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: ['eks:DescribeCluster'],
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${cluster.clusterName}`],
    }));
    cluster.awsAuth.addRoleMapping(postConfirmFn.role!, {
      groups: ['system:masters'],
      username: 'lambda-post-confirm',
    });
    cluster.awsAuth.addRoleMapping(tenantBuilder.role!, {
      groups: ['system:masters'],
      username: 'codebuild-tenant-builder',
    });

    // ── IAM: EBS Snapshot (for PVC backup CronJob) ──────────────────────────
    const snapshotRole = new iam.Role(this, 'EbsSnapshotRole', {
      roleName: `EbsSnapshotRole-${cluster.clusterName}`,
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
    });
    snapshotRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      actions: ['sts:TagSession'],
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
    }));
    snapshotRole.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: ['ec2:CreateSnapshot', 'ec2:DeleteSnapshot', 'ec2:DescribeSnapshots', 'ec2:DescribeVolumes', 'ec2:CreateTags'],
      resources: ['*'],
    }));

    // ── CloudFront + WAF ────────────────────────────────────────────────────
    const wafAcl = new wafv2.CfnWebACL(this, 'WafAcl', {
      defaultAction: { allow: {} },
      scope: 'REGIONAL',
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: 'OpenClawWaf',
        sampledRequestsEnabled: true,
      },
      rules: [
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
      ],
    });

    // S3 bucket for auth UI static site
    const authUiBucket = new s3.Bucket(this, 'AuthUiBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    const oai = new cloudfront.OriginAccessIdentity(this, 'AuthUiOAI');
    authUiBucket.grantRead(oai);

    const distribution = new cloudfront.CloudFrontWebDistribution(this, 'Distribution', {
      
      viewerCertificate: cloudfront.ViewerCertificate.fromAcmCertificate(
        acm.Certificate.fromCertificateArn(this, 'CfCert',
          // CloudFront requires us-east-1 cert — use the same cert if in us-east-1,
          // otherwise need a separate cert. For now, use the existing cert ARN.
          // NOTE: If your cert is NOT in us-east-1, you must create one there.
          this.node.tryGetContext('cloudfrontCertificateArn') || certificate.certificateArn,
        ),
        {
          aliases: [domainName],
          securityPolicy: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
        },
      ),
      originConfigs: [
        {
          // Auth UI static site (login, signup, welcome pages)
          s3OriginSource: {
            s3BucketSource: authUiBucket,
            originAccessIdentity: oai,
          },
          behaviors: [
            {
              isDefaultBehavior: true,
              viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            },
          ],
        },
      ],
      errorConfigurations: [
        { errorCode: 404, responseCode: 200, responsePagePath: '/index.html' },
        { errorCode: 403, responseCode: 200, responsePagePath: '/index.html' },
      ],
    });


    // ── Route53 + WAF + ALB Origin ──────────────────────────────────────────
    // These resources depend on the Kubernetes-managed ALB (dynamic).
    // Managed by scripts/post-deploy.sh after first tenant creation:
    //   - Route53 root domain → CloudFront #1 (auth UI)
    //   - Route53 wildcard → CloudFront #2 (tenant traffic)
    //   - WAF → ALB association
    //   - Internet-facing ALB (CF-only SG + WAF)
    //   - CloudFront #2 distribution (*.domain → ALB)

















    // ── WAF → ALB Association ───────────────────────────────────────────────
    // ALB ARN is dynamic (created by LB Controller, not CDK). Associate via script.
    // See scripts/setup-waf.sh

    // ── Lambda: Cost Enforcer ───────────────────────────────────────────────
    const costEnforcerFn = new lambda.Function(this, 'CostEnforcerFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/cost-enforcer'),
      environment: {
        CLUSTER_NAME: cluster.clusterName,
        CERTIFICATE_ARN: certificate.certificateArn,
        LOG_GROUP: `/aws/containerinsights/${cluster.clusterName}/application`,
        SNS_TOPIC_ARN: alertsTopic.topicArn,
        REGION: this.region,
      },
      timeout: cdk.Duration.minutes(5),
      memorySize: 256,
    });
    alertsTopic.grantPublish(costEnforcerFn);
    costEnforcerFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['logs:StartQuery', 'logs:GetQueryResults'],
      resources: [`arn:aws:logs:${this.region}:${this.account}:log-group:/aws/containerinsights/${cluster.clusterName}/*`],
    }));
    costEnforcerFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:DescribeSecret', 'secretsmanager:ListSecrets'],
      resources: ['*'],
    }));

    new events.Rule(this, 'CostEnforcerSchedule', {
      schedule: events.Schedule.rate(cdk.Duration.days(1)),
      targets: [new events_targets.LambdaFunction(costEnforcerFn)],
    });

    // ── Outputs ─────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ClusterName', { value: cluster.clusterName });
    new cdk.CfnOutput(this, 'ClusterEndpoint', { value: cluster.clusterEndpoint });
    new cdk.CfnOutput(this, 'TenantRoleArn', { value: tenantRole.roleArn });
    new cdk.CfnOutput(this, 'KubeconfigCommand', {
      value: `aws eks update-kubeconfig --region ${this.region} --name ${cluster.clusterName}`,
    });
    new cdk.CfnOutput(this, 'DomainName', { value: domainName });
    new cdk.CfnOutput(this, 'CertificateArn', { value: certificate.certificateArn });
    new cdk.CfnOutput(this, 'CognitoPoolId', { value: userPool.userPoolId });
    new cdk.CfnOutput(this, 'CognitoClientId', { value: cognitoClientId });
    new cdk.CfnOutput(this, 'CognitoDomain', { value: cognitoDomain });
    new cdk.CfnOutput(this, 'AlertsTopicArn', { value: alertsTopic.topicArn });
    new cdk.CfnOutput(this, 'ErrorPagesBucketName', { value: errorPagesBucket.bucketName });
    new cdk.CfnOutput(this, 'PreSignupFnArn', { value: preSignupFn.functionArn });
    new cdk.CfnOutput(this, 'PostConfirmFnArn', { value: postConfirmFn.functionArn });
    new cdk.CfnOutput(this, 'EbsSnapshotRoleArn', { value: snapshotRole.roleArn });
    new cdk.CfnOutput(this, 'AuthUiBucketName', { value: authUiBucket.bucketName });
    new cdk.CfnOutput(this, 'DistributionDomainName', { value: distribution.distributionDomainName });
    new cdk.CfnOutput(this, 'WafAclArn', { value: wafAcl.attrArn });
    new cdk.CfnOutput(this, 'CloudFrontCertificateArn', { value: this.node.tryGetContext('cloudfrontCertificateArn') || '' });

  }
}
