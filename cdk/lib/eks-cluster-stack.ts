import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as events from 'aws-cdk-lib/aws-events';
import * as events_targets from 'aws-cdk-lib/aws-events-targets';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cw_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as efs from 'aws-cdk-lib/aws-efs';
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

    // gp3 StorageClass — kept for backward compatibility during EFS migration
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

    // ── EFS FileSystem (multi-AZ, per-tenant access points via CSI dynamic provisioning) ──
    const fileSystem = new efs.FileSystem(this, 'TenantEfs', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      encrypted: true,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: efs.ThroughputMode.ELASTIC,
      lifecyclePolicy: efs.LifecyclePolicy.AFTER_30_DAYS,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    fileSystem.connections.allowFrom(cluster, ec2.Port.tcp(2049), 'EKS nodes → EFS NFS');

    // ── EFS CSI Driver (with Pod Identity IAM) ──────────────────────────────
    const efsCsiRole = new iam.Role(this, 'EfsCsiRole', {
      roleName: `EfsCsiDriverRole-${cluster.clusterName}`,
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonEFSCSIDriverPolicy'),
      ],
    });
    efsCsiRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      actions: ['sts:TagSession'],
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
    }));

    const efsCsiAddon = new eks.CfnAddon(this, 'EfsCsiDriver', {
      clusterName: cluster.clusterName,
      addonName: 'aws-efs-csi-driver',
      podIdentityAssociations: [{
        roleArn: efsCsiRole.roleArn,
        serviceAccount: 'efs-csi-controller-sa',
      }],
    });
    efsCsiAddon.node.addDependency(fileSystem);

    // efs-sc StorageClass — dynamic provisioning creates per-tenant access points
    const efsStorageClass = cluster.addManifest('EfsStorageClass', {
      apiVersion: 'storage.k8s.io/v1',
      kind: 'StorageClass',
      metadata: { name: 'efs-sc' },
      provisioner: 'efs.csi.aws.com',
      parameters: {
        provisioningMode: 'efs-ap',
        fileSystemId: fileSystem.fileSystemId,
        directoryPerms: '0755',
        basePath: '/tenants',
        subPathPattern: '${.PVC.namespace}',
        ensureUniqueDirectory: 'false',
        // OpenClaw runs as uid:gid 1000:1000 (node user). All APs use the same
        // GID so the container can read/write without running as root.
        // GID 1000 for all APs — matches OpenClaw container user (node:1000:1000).
        // Intentionally same start/end: all tenants share UID/GID, isolation is via AP chroot.
        gidRangeStart: '1000',
        gidRangeEnd: '1000',
      },
      reclaimPolicy: 'Delete',
      volumeBindingMode: 'Immediate',
    });
    efsStorageClass.node.addDependency(fileSystem);
    efsStorageClass.node.addDependency(efsCsiAddon);

    new cdk.CfnOutput(this, 'EfsFileSystemId', { value: fileSystem.fileSystemId });

    // ── Pod Security Standards ─────────────────────────────────────────────
    cluster.addManifest('PodSecurityStandards', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: {
        name: 'openclaw-system',
        labels: {
          'pod-security.kubernetes.io/enforce': 'restricted',
          'pod-security.kubernetes.io/warn': 'restricted',
          'pod-security.kubernetes.io/audit': 'restricted',
        },
      },
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
        'elasticloadbalancing:DescribeRules', 'elasticloadbalancing:ModifyRule', 'elasticloadbalancing:SetRulePriorities',
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

    // ── Context Validation ─────────────────────────────────────────────────
    // Warn on placeholder values that will produce broken IAM policies or
    // Cognito custom resources. CI uses cdk.json.example (non-empty placeholders)
    // so synth passes, but empty values indicate a misconfigured cdk.json.
    const contextChecks: Record<string, string> = {
      cognitoPoolId, cognitoClientId, cognitoDomain,
    };
    for (const [key, val] of Object.entries(contextChecks)) {
      if (!val) {
        cdk.Annotations.of(this).addWarningV2(`OpenClaw:${key}`,
          `CDK context '${key}' is empty. Lambda IAM policies and Cognito triggers will be misconfigured. ` +
          `Fill in cdk/cdk.json or run setup.sh to generate it.`);
      }
    }

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

    // Cold start alarm — alert when pod startup exceeds 60s
    const perfLogGroup = logs.LogGroup.fromLogGroupName(this, 'PerfLogGroup',
      `/aws/containerinsights/${cluster.clusterName}/performance`);
    const coldStartFilter = new logs.MetricFilter(this, 'ColdStartFilter', {
      logGroup: perfLogGroup,
      filterPattern: logs.FilterPattern.all(
        logs.FilterPattern.stringValue('$.Type', '=', 'Pod'),
        logs.FilterPattern.stringValue('$.PodStatus', '=', 'Running'),
        logs.FilterPattern.exists('$.pod_startup_duration_seconds'),
      ),
      metricNamespace: 'OpenClaw/ColdStart',
      metricName: 'PodStartupDurationSeconds',
      metricValue: '$.pod_startup_duration_seconds',
      defaultValue: 0,
    });
    const coldStartAlarm = new cloudwatch.Alarm(this, 'ColdStartAlarm', {
      alarmName: 'OpenClaw-PodColdStartSlow',
      metric: coldStartFilter.metric({ statistic: 'Maximum', period: cdk.Duration.seconds(300) }),
      evaluationPeriods: 1,
      threshold: 60,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    coldStartAlarm.addAlarmAction(new cw_actions.SnsAction(alertsTopic));

    // Bedrock latency alarm — alert when P95 response time exceeds 10s
    const appLogGroup = logs.LogGroup.fromLogGroupName(this, 'AppLogGroup',
      `/aws/containerinsights/${cluster.clusterName}/application`);
    const bedrockLatencyFilter = new logs.MetricFilter(this, 'BedrockLatencyFilter', {
      logGroup: appLogGroup,
      filterPattern: logs.FilterPattern.literal('{ $.message = "*bedrock*response*" && $.duration = * }'),
      metricNamespace: 'OpenClaw/Bedrock',
      metricName: 'BedrockResponseTimeMs',
      metricValue: '$.duration',
      defaultValue: 0,
    });
    const bedrockLatencyAlarm = new cloudwatch.Alarm(this, 'BedrockLatencyAlarm', {
      alarmName: 'OpenClaw-BedrockP95Latency',
      metric: bedrockLatencyFilter.metric({ statistic: 'p95', period: cdk.Duration.seconds(300) }),
      evaluationPeriods: 2,
      threshold: 10000,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    bedrockLatencyAlarm.addAlarmAction(new cw_actions.SnsAction(alertsTopic));

    // ── OpenClaw Image ──────────────────────────────────────────────────────
    // Default: pull directly from ghcr.io (public, no credentials needed).
    // To enable ECR pull-through cache for production:
    //   1. Create a GHCR PAT and store in Secrets Manager (name: ecr-pullthroughcache/ghcr)
    //   2. Set ghcrCredentialArn in cdk.json to the secret ARN
    //   3. cdk deploy — images will be cached in ECR automatically
    const ghcrCredentialArn = this.node.tryGetContext('ghcrCredentialArn') as string | undefined;
    if (ghcrCredentialArn) {
      new ecr.CfnPullThroughCacheRule(this, 'GhcrCache', {
        ecrRepositoryPrefix: 'ghcr',
        upstreamRegistryUrl: 'ghcr.io',
        credentialArn: ghcrCredentialArn,
      });
    }
    const openclawImage = this.node.tryGetContext('openclawImage')
      || (ghcrCredentialArn
        ? `${this.account}.dkr.ecr.${this.region}.amazonaws.com/ghcr/openclaw/openclaw:latest`
        : 'ghcr.io/openclaw/openclaw:latest');

    // ── S3: Error Pages Bucket ──────────────────────────────────────────────
    const errorPagesBucket = new s3.Bucket(this, 'ErrorPagesBucket', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // S3: tenant pods read chart assets from error-pages bucket
    tenantRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'S3ChartRead',
      actions: ['s3:GetObject', 's3:HeadObject'],
      resources: [errorPagesBucket.arnForObjects('*')],
    }));

    // ── Lambda: Pre-Signup ──────────────────────────────────────────────────
    const preSignupFn = new lambda.Function(this, 'PreSignupFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/pre-signup'),
      environment: { SNS_TOPIC_ARN: alertsTopic.topicArn, ALLOWED_DOMAINS: allowedEmailDomains, USER_POOL_ID: cognitoPoolId },
      timeout: cdk.Duration.seconds(10),
    });
    alertsTopic.grantPublish(preSignupFn);
    preSignupFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:ListUsers'],
      resources: [`arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`],
    }));

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
        OPENCLAW_IMAGE: openclawImage,
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
      actions: ['iam:PassRole', 'iam:GetRole'],
      resources: [tenantRole.roleArn],
    }));

    // ── Cognito: Lambda Triggers (survives cdk deploy) ──────────────────────
    // update-user-pool wipes LambdaConfig if not included. This Custom Resource
    // ensures triggers are always re-attached after every deployment.
    const selfSignupEnabled = this.node.tryGetContext('selfSignupEnabled') !== false;

    // Lambda invoke permissions for Cognito (must exist before Custom Resource)
    preSignupFn.addPermission('CognitoInvoke', {
      principal: new iam.ServicePrincipal('cognito-idp.amazonaws.com'),
      sourceArn: `arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`,
    });
    postConfirmFn.addPermission('CognitoInvoke', {
      principal: new iam.ServicePrincipal('cognito-idp.amazonaws.com'),
      sourceArn: `arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`,
    });

    new cr.AwsCustomResource(this, 'CognitoTriggers', {
      onCreate: {
        service: 'CognitoIdentityServiceProvider',
        action: 'updateUserPool',
        parameters: {
          UserPoolId: cognitoPoolId,
          LambdaConfig: {
            PreSignUp: preSignupFn.functionArn,
            PostConfirmation: postConfirmFn.functionArn,
          },
          AutoVerifiedAttributes: ['email'],
          AdminCreateUserConfig: { AllowAdminCreateUserOnly: !selfSignupEnabled },
        },
        physicalResourceId: cr.PhysicalResourceId.of('cognito-triggers'),
      },
      onUpdate: {
        service: 'CognitoIdentityServiceProvider',
        action: 'updateUserPool',
        parameters: {
          UserPoolId: cognitoPoolId,
          LambdaConfig: {
            PreSignUp: preSignupFn.functionArn,
            PostConfirmation: postConfirmFn.functionArn,
          },
          AutoVerifiedAttributes: ['email'],
          AdminCreateUserConfig: { AllowAdminCreateUserOnly: !selfSignupEnabled },
        },
        physicalResourceId: cr.PhysicalResourceId.of('cognito-triggers'),
      },
      onDelete: {
        service: 'CognitoIdentityServiceProvider',
        action: 'updateUserPool',
        parameters: {
          UserPoolId: cognitoPoolId,
          LambdaConfig: {},
        },
        physicalResourceId: cr.PhysicalResourceId.of('cognito-triggers'),
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          actions: ['cognito-idp:UpdateUserPool'],
          resources: [`arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`],
        }),
      ]),
    });

    // ── Cognito: App Client ReadAttributes (include custom:gateway_token) ───
    // Without explicit ReadAttributes, custom attributes are NOT included in
    // ID token claims. This ensures auth-ui can read the gateway token.
    new cr.AwsCustomResource(this, 'CognitoClientAttributes', {
      onCreate: {
        service: 'CognitoIdentityServiceProvider',
        action: 'updateUserPoolClient',
        parameters: {
          UserPoolId: cognitoPoolId,
          ClientId: cognitoClientId,
          ReadAttributes: ['email', 'custom:gateway_token', 'custom:tenant_name'],
          WriteAttributes: ['email'],
        },
        physicalResourceId: cr.PhysicalResourceId.of('cognito-client-attrs'),
      },
      onUpdate: {
        service: 'CognitoIdentityServiceProvider',
        action: 'updateUserPoolClient',
        parameters: {
          UserPoolId: cognitoPoolId,
          ClientId: cognitoClientId,
          ReadAttributes: ['email', 'custom:gateway_token', 'custom:tenant_name'],
          WriteAttributes: ['email'],
        },
        physicalResourceId: cr.PhysicalResourceId.of('cognito-client-attrs'),
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          actions: ['cognito-idp:UpdateUserPoolClient'],
          resources: [`arn:aws:cognito-idp:${this.region}:${this.account}:userpool/${cognitoPoolId}`],
        }),
      ]),
    });

    cluster.awsAuth.addRoleMapping(postConfirmFn.role!, {
      groups: ['system:masters'],
      username: 'lambda-post-confirm',
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
    const enableBotControl = this.node.tryGetContext('enableBotControl') === true;

    const wafRules: wafv2.CfnWebACL.RuleProperty[] = [
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

    // Bot Control: opt-in via CDK context (incurs additional WAF charges)
    if (enableBotControl) {
      wafRules.push({
        name: 'AWSManagedRulesBotControlRuleSet',
        priority: 3,
        overrideAction: { none: {} },
        statement: {
          managedRuleGroupStatement: {
            vendorName: 'AWS',
            name: 'AWSManagedRulesBotControlRuleSet',
            managedRuleGroupConfigs: [{
              awsManagedRulesBotControlRuleSet: {
                inspectionLevel: 'COMMON',
              },
            }],
          },
        },
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: 'BotControl',
          sampledRequestsEnabled: true,
        },
      });
    }

    const wafAcl = new wafv2.CfnWebACL(this, 'WafAcl', {
      defaultAction: { allow: {} },
      scope: 'REGIONAL',
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: 'OpenClawWaf',
        sampledRequestsEnabled: true,
      },
      rules: wafRules,
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

    // ── Auth UI: Deploy static files + generate config.js ───────────────────
    const configJs = `const C={region:'${this.region}',userPoolId:'${cognitoPoolId}',clientId:'${cognitoClientId}',domain:'${domainName}'};`;

    new s3deploy.BucketDeployment(this, 'AuthUiDeployment', {
      sources: [
        s3deploy.Source.asset('../auth-ui'),
        s3deploy.Source.data('config.js', configJs),
      ],
      destinationBucket: authUiBucket,
      distribution,
      distributionPaths: ['/*'],
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
    new cdk.CfnOutput(this, 'OpenClawImageUri', { value: openclawImage });
  }
}
