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
import * as iam from 'aws-cdk-lib/aws-iam';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as efs from 'aws-cdk-lib/aws-efs';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import { KubectlV35Layer } from '@aws-cdk/lambda-layer-kubectl-v35';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export class EksClusterStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ── Validate required CDK context (before any resource creation) ─────
    // Skip validation during CI synth (uses placeholder values from cdk.json.example)
    if (!this.node.tryGetContext('@ci-synth')) {
      const requiredContext: Record<string, string> = {
        allowedEmailDomains: 'Email domain allowlist (e.g., your-company.com)',
        githubOwner: 'GitHub org for Helm chart repo',
      };
      const missingCtx = Object.entries(requiredContext)
        .filter(([key]) => {
          const val = this.node.tryGetContext(key);
          if (typeof val !== 'string' || !val) return true;
          return val.startsWith('your-') || val === 'us-west-2_XXXXXXXXX' || val === 'xxxxxxxxxxxxxxxxxx';
        })
        .map(([key, desc]) => `  - ${key}: ${desc}`);
      if (missingCtx.length > 0) {
        throw new Error(
          `Missing required CDK context values in cdk.json:\n${missingCtx.join('\n')}\n\n` +
          'Copy cdk/cdk.json.example to cdk/cdk.json and fill in your values.\n' +
          'See README.md "Prerequisites" for details.',
        );
      }
    }

    // ── VPC ─────────────────────────────────────────────────────────────────
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 2,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // Tag private subnets for Karpenter EC2NodeClass subnet discovery.
    // Karpenter requires both 'internal-elb' and cluster-owned tags to match.
    // CDK adds 'internal-elb' automatically but not the cluster-owned tag.
    // Derive unique cluster name from stack name to prevent tag collisions
    // across deployments. Context override is available for advanced users.
    const stackSuffix = this.stackName.replace(/^OpenClawEksStack-/, '');
    const clusterName = (this.node.tryGetContext('clusterName') as string) || `openclaw-${stackSuffix}`;
    for (const subnet of vpc.privateSubnets) {
      cdk.Tags.of(subnet).add(`kubernetes.io/cluster/${clusterName}`, 'owned');
    }

    // VPC Endpoints — reduce NAT Gateway costs for AWS service traffic
    // S3 Gateway endpoint is free; Interface endpoints ~$7/mo/AZ
    vpc.addGatewayEndpoint('S3Endpoint', { service: ec2.GatewayVpcEndpointAwsService.S3 });
    vpc.addInterfaceEndpoint('StsEndpoint', { service: ec2.InterfaceVpcEndpointAwsService.STS });
    vpc.addInterfaceEndpoint('EcrApiEndpoint', { service: ec2.InterfaceVpcEndpointAwsService.ECR });
    vpc.addInterfaceEndpoint('EcrDkrEndpoint', { service: ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER });

    // ── EKS Cluster ─────────────────────────────────────────────────────────
    // VPC Flow Logs — network forensics for all traffic
    new ec2.FlowLog(this, 'VpcFlowLog', {
      resourceType: ec2.FlowLogResourceType.fromVpc(vpc),
      destination: ec2.FlowLogDestination.toCloudWatchLogs(),
      trafficType: ec2.FlowLogTrafficType.ALL,
    });

    // KMS key for EKS envelope encryption of Kubernetes secrets
    const eksSecretsKey = new kms.Key(this, 'EksSecretsKey', {
      alias: `openclaw/${this.stackName}/eks-secrets`,
      description: 'Envelope encryption for Kubernetes secrets in EKS cluster',
      enableKeyRotation: true,
    });

    const cluster = new eks.Cluster(this, 'Cluster', {
      vpc,
      version: eks.KubernetesVersion.V1_35,
      defaultCapacity: 0,
      clusterName,
      authenticationMode: eks.AuthenticationMode.API_AND_CONFIG_MAP,
      kubectlLayer: new KubectlV35Layer(this, 'KubectlLayer'),
      secretsEncryptionKey: eksSecretsKey,
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
        eks.ClusterLoggingTypes.CONTROLLER_MANAGER,
        eks.ClusterLoggingTypes.SCHEDULER,
      ],
    });

    // ── Cluster Access: allow deployer to use kubectl ─────────
    // Users must set 'deployerPrincipalArn' to their IAM principal ARN.
    // This can be any IAM identity: IAM user, IAM role, or SSO/Identity Center role.
    // It does NOT require IAM Identity Center — any IAM principal works.
    // Example: cdk deploy -c deployerPrincipalArn=arn:aws:iam::123456789012:role/MyRole
    const deployerArn = this.node.tryGetContext('deployerPrincipalArn') || this.node.tryGetContext('ssoRoleArn');
    if (deployerArn) {
      new eks.CfnAccessEntry(this, 'DeployerAccess', {
        clusterName: cluster.clusterName,
        principalArn: deployerArn,
        type: 'STANDARD',
        accessPolicies: [{
          accessScope: { type: 'cluster' },
          policyArn: 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy',
        }],
      });
    }

    // ── Managed Node Group ──────────────────────────────────────────────────
    // 2x t4g.large (4 vCPU, 8 GiB) for system pods (~7.4 vCPU total requests).
    cluster.addNodegroupCapacity('SystemNodes', {
      instanceTypes: [new ec2.InstanceType('t4g.large')],
      amiType: eks.NodegroupAmiType.AL2023_ARM_64_STANDARD,
      minSize: 2,
      maxSize: 4,
      desiredSize: 3,
      nodegroupName: 'system-graviton',
      labels: { role: 'system' },
    });

    // ── EBS CSI Driver (with Pod Identity IAM) ──────────────────────────────
    const ebsCsiRole = new iam.Role(this, 'EbsCsiRole', {
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
    new eks.KubernetesManifest(this, 'Gp3StorageClass', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
        apiVersion: 'storage.k8s.io/v1',
        kind: 'StorageClass',
        metadata: { name: 'gp3' },
        provisioner: 'ebs.csi.aws.com',
        parameters: { type: 'gp3', fsType: 'ext4' },
        reclaimPolicy: 'Delete',
        volumeBindingMode: 'WaitForFirstConsumer',
        allowVolumeExpansion: true,
      }],
      overwrite: true,
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
    fileSystem.connections.allowFrom(cluster, ec2.Port.tcp(2049), 'EKS nodes to EFS NFS');

    // ── EFS CSI Driver (with Pod Identity IAM) ──────────────────────────────
    const efsCsiRole = new iam.Role(this, 'EfsCsiRole', {
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

    // EFS resource policy — allow mount from any principal via mount target.
    // The EFS CSI node DaemonSet uses the node instance profile (not the controller's
    // Pod Identity role) to mount volumes, so we must allow all principals here.
    // Security is enforced by: (1) mount target lives in private subnets only,
    // (2) security group restricts NFS port to EKS nodes, (3) access points
    // enforce per-tenant POSIX UID/GID isolation.
    fileSystem.addToResourcePolicy(new iam.PolicyStatement({
      actions: ['elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite', 'elasticfilesystem:ClientRootAccess'],
      principals: [new iam.AnyPrincipal()],
      conditions: {
        Bool: { 'elasticfilesystem:AccessedViaMountTarget': 'true' },
      },
    }));

    // efs-sc StorageClass — dynamic provisioning creates per-tenant access points
    const efsStorageClass = new eks.KubernetesManifest(this, 'EfsStorageClass', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
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
          // GID range for EFS access points. Each tenant gets a unique GID.
          // Range must be large enough for max expected tenants.
          gidRangeStart: '1000',
          gidRangeEnd: '2000',
        },
        reclaimPolicy: 'Delete',
        volumeBindingMode: 'Immediate',
      }],
      overwrite: true,
    });
    efsStorageClass.node.addDependency(fileSystem);
    efsStorageClass.node.addDependency(efsCsiAddon);

    new cdk.CfnOutput(this, 'EfsFileSystemId', { value: fileSystem.fileSystemId });

    // ── Pod Security Standards ─────────────────────────────────────────────
    new eks.KubernetesManifest(this, 'PodSecurityStandards', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
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
      }],
      overwrite: true,
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
      // Wildcard required: AWS Load Balancer Controller manages dynamically-created
      // ALBs, target groups, security groups, and listeners. Resource ARNs are not
      // known at deploy time. See: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/#iam-permissions
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(lbcSa.role, [{
      id: 'AwsSolutions-IAM5',
      reason: 'AWS Load Balancer Controller requires wildcard resources to manage dynamically-created ALBs, target groups, and security groups. Per official IAM policy: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/#iam-permissions',
    }], true);

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
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    new iam.CfnInstanceProfile(this, 'KarpenterInstanceProfile', {
      roles: [karpenterNodeRole.roleName],
    });

    cluster.awsAuth.addRoleMapping(karpenterNodeRole, {
      groups: ['system:bootstrappers', 'system:nodes'],
      username: 'system:node:{{EC2PrivateDNSName}}',
    });

    // Namespace (must exist before SA)
    const karpenterNs = new eks.KubernetesManifest(this, 'KarpenterNs', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
        apiVersion: 'v1',
        kind: 'Namespace',
        metadata: { name: 'karpenter' },
      }],
      overwrite: true,
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
      // Wildcard required: Karpenter dynamically provisions and terminates EC2
      // instances, launch templates, and instance profiles. Resource ARNs are
      // generated at runtime. See: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/#create-the-karpenter-iam-role
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(karpenterSa.role, [{
      id: 'AwsSolutions-IAM5',
      reason: 'Karpenter requires wildcard resources to dynamically provision EC2 instances, launch templates, and instance profiles. Per official IAM policy: https://karpenter.sh/docs/getting-started/',
    }], true);

    // Helm chart
    const karpenterChart = cluster.addHelmChart('Karpenter', {
      chart: 'karpenter',
      repository: 'oci://public.ecr.aws/karpenter/karpenter',
      namespace: 'karpenter',
      createNamespace: false,
      // Karpenter v1.3.x uses karpenter.sh/v1 and karpenter.k8s.aws/v1 APIs.
      // When upgrading, check API version compatibility: https://karpenter.sh/docs/upgrading/
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
    const nodeClass = new eks.KubernetesManifest(this, 'KarpenterNodeClass', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
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
      }],
      overwrite: true,
    });
    nodeClass.node.addDependency(karpenterChart);

    // NodePool
    const nodePool = new eks.KubernetesManifest(this, 'KarpenterNodePool', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      cluster,
      manifest: [{
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
                { key: 'karpenter.k8s.aws/instance-category', operator: 'In', values: ['c', 'm', 'r', 't'] },
                { key: 'karpenter.k8s.aws/instance-generation', operator: 'Gt', values: ['2'] },
                { key: 'karpenter.k8s.aws/instance-size', operator: 'In', values: ['medium', 'large', 'xlarge'] },
              ],
            },
          },
          limits: { cpu: '100' },
          disruption: {
            consolidationPolicy: 'WhenEmptyOrUnderutilized',
            consolidateAfter: '1m',
          },
        },
      }],
      overwrite: true,
    });
    nodePool.node.addDependency(nodeClass);

    // ── ArgoCD ────────────────────────────────────────────────────────────
    // Installed via Helm (scripts/setup-argocd.sh). For production, consider EKS Capability:
    //   aws eks create-capability --type ARGOCD (requires AWS Identity Center)
    // See scripts/setup-argocd.sh for details.
    // EKS Capability provides: fully managed ArgoCD, automatic upgrades, Identity Center auth.

    // ── Shared Tenant IAM Role ──────────────────────────────────────────────
    const tenantRole = new iam.Role(this, 'TenantRole', {
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
      // Wildcard required: ListFoundationModels and ListInferenceProfiles are
      // account-level APIs that only support '*' as resource ARN.
      // See: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(tenantRole, [{
      id: 'AwsSolutions-IAM5',
      reason: 'Amazon Bedrock ListFoundationModels/ListInferenceProfiles are account-level APIs that only support wildcard resource. See: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html',
      appliesTo: ['Resource::*'],
    }], true);

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

    // ── Other imported/optional resources ────────────────────────────────────
    const domainName = this.node.tryGetContext('zoneName') || '';
    const useCustomDomain = !!domainName && domainName !== 'example.com';
    const allowedEmailDomains = this.node.tryGetContext('allowedEmailDomains') || 'example.com';
    const githubOwner = this.node.tryGetContext('githubOwner') || '';
    const githubRepo = this.node.tryGetContext('githubRepo') || 'openclaw-platform';

    const certArn = this.node.tryGetContext('certificateArn') || '';
    const certificate = certArn
      ? acm.Certificate.fromCertificateArn(this, 'Certificate', certArn)
      : undefined;

    // ── CloudWatch Alerts ──────────────────────────────────────────────────
    const alertsTopic = new sns.Topic(this, 'AlertsTopic', {
      topicName: `${this.stackName}-Alerts`,
      masterKey: eksSecretsKey,
    });

    const podRestartAlarm = new cloudwatch.Alarm(this, 'PodRestartAlarm', {
      alarmName: `${this.stackName}-PodRestartCount`,
      metric: new cloudwatch.Metric({
        namespace: 'ContainerInsights',
        metricName: 'pod_number_of_container_restarts',
        dimensionsMap: { ClusterName: cluster.clusterName },
        period: cdk.Duration.seconds(300),
        statistic: 'Sum',
      }),
      evaluationPeriods: 1,
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
    });
    podRestartAlarm.addAlarmAction(new cw_actions.SnsAction(alertsTopic));

    // Cold start alarm — alert when pod startup exceeds 60s
    // Create log groups explicitly so MetricFilters don't fail when
    // Container Insights hasn't created them yet. retentionDays ensures
    // CDK owns the log group; Container Insights will write to it once active.
    const perfLogGroup = new logs.LogGroup(this, 'PerfLogGroup', {
      logGroupName: `/aws/containerinsights/${cluster.clusterName}/performance`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
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
      alarmName: `${this.stackName}-PodColdStartSlow`,
      metric: coldStartFilter.metric({ statistic: 'Maximum', period: cdk.Duration.seconds(300) }),
      evaluationPeriods: 1,
      threshold: 60,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    coldStartAlarm.addAlarmAction(new cw_actions.SnsAction(alertsTopic));

    // Bedrock latency alarm — alert when P95 response time exceeds 10s
    const appLogGroup = new logs.LogGroup(this, 'AppLogGroup', {
      logGroupName: `/aws/containerinsights/${cluster.clusterName}/application`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const bedrockLatencyFilter = new logs.MetricFilter(this, 'BedrockLatencyFilter', {
      logGroup: appLogGroup,
      filterPattern: logs.FilterPattern.literal('{ $.message = "*bedrock*response*" && $.duration = * }'),
      metricNamespace: 'OpenClaw/Bedrock',
      metricName: 'BedrockResponseTimeMs',
      metricValue: '$.duration',
      defaultValue: 0,
    });
    const bedrockLatencyAlarm = new cloudwatch.Alarm(this, 'BedrockLatencyAlarm', {
      alarmName: `${this.stackName}-BedrockP95Latency`,
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

    // ── Lambda: Pre-Signup ──────────────────────────────────────────────────
    const selfSignupEnabled = this.node.tryGetContext('selfSignupEnabled') !== false;

    // Dead-letter queue for Lambda trigger failures
    const triggerDlq = new sqs.Queue(this, 'TriggerDLQ', {
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      retentionPeriod: cdk.Duration.days(14),
    });

    const preSignupFn = new lambda.Function(this, 'PreSignupFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/pre-signup'),
      environment: { SNS_TOPIC_ARN: alertsTopic.topicArn, ALLOWED_DOMAINS: allowedEmailDomains, SIGNUP_RATE_LIMIT: '20' },
      timeout: cdk.Duration.seconds(10),
      deadLetterQueue: triggerDlq,
    });
    alertsTopic.grantPublish(preSignupFn);

    // ── Lambda: Post-Confirmation ───────────────────────────────────────────
    const postConfirmFn = new lambda.Function(this, 'PostConfirmFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/post-confirmation'),
      environment: {
        SNS_TOPIC_ARN: alertsTopic.topicArn,
        CLUSTER_NAME: cluster.clusterName,
        CERTIFICATE_ARN: certificate?.certificateArn || '',
        DOMAIN: domainName,
        OPENCLAW_IMAGE: openclawImage,
        TENANT_ROLE_ARN: tenantRole.roleArn,
      },
      timeout: cdk.Duration.seconds(60),
      deadLetterQueue: triggerDlq,
    });
    alertsTopic.grantPublish(postConfirmFn);
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:CreateSecret', 'secretsmanager:TagResource', 'secretsmanager:GetSecretValue', 'secretsmanager:RestoreSecret', 'secretsmanager:UpdateSecret'],
      resources: [`arn:aws:secretsmanager:${this.region}:${this.account}:secret:openclaw/*`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['eks:CreatePodIdentityAssociation', 'eks:DescribeCluster'],
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${cluster.clusterName}`],
    }));
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['iam:PassRole', 'iam:GetRole'],
      resources: [tenantRole.roleArn],
    }));

    // ── Cognito: Complete UserPool with Lambda Triggers ──────────────────
    // Set triggers in constructor. Use attachInlinePolicy (not addToRolePolicy)
    // for Cognito-scoped permissions to avoid circular dependency.
    // See: https://github.com/aws/aws-cdk/issues/7016
    const cognitoDomainPrefix = this.node.tryGetContext('cognitoDomain')
      || `openclaw-${this.account}-${this.region}`;

    const userPool = new cognito.UserPool(this, 'UserPool', {
      userPoolName: `openclaw-${this.stackName}`,
      selfSignUpEnabled: selfSignupEnabled,
      signInAliases: { email: true },
      autoVerify: { email: true },
      passwordPolicy: {
        minLength: 12,
        requireUppercase: true,
        requireLowercase: true,
        requireDigits: true,
        requireSymbols: false,
      },
      customAttributes: {
        gateway_token: new cognito.StringAttribute({ mutable: true }),
        tenant_name: new cognito.StringAttribute({ mutable: true }),
      },
      // SYSTEMATIC FIX: Native CDK trigger configuration (eliminates custom resource)
      lambdaTriggers: {
        preSignUp: preSignupFn,
        postConfirmation: postConfirmFn,
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Explicit L1 override: ensure self-signup is always enabled.
    // CDK's selfSignUpEnabled maps to AllowAdminCreateUserOnly=false, but
    // CloudFormation has been observed to default to true on fresh deploys.
    (userPool.node.defaultChild as cognito.CfnUserPool).addPropertyOverride(
      'AdminCreateUserConfig.AllowAdminCreateUserOnly', false);

    userPool.addDomain('CognitoDomain', {
      cognitoDomain: { domainPrefix: cognitoDomainPrefix },
    });

    const userPoolClient = userPool.addClient('WebClient', {
      generateSecret: false,
      authFlows: { userPassword: true, userSrp: true },
      readAttributes: new cognito.ClientAttributes()
        .withStandardAttributes({ email: true })
        .withCustomAttributes('gateway_token', 'tenant_name'),
      writeAttributes: new cognito.ClientAttributes()
        .withStandardAttributes({ email: true }),
    });

    // Cognito-scoped IAM — use wildcard to avoid circular dependency
    // (attachInlinePolicy with userPool.userPoolArn still creates cycle)
    preSignupFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:ListUsers'],
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(preSignupFn, [{
      id: 'AwsSolutions-IAM5',
      reason: 'Wildcard required to avoid circular dependency between UserPool and Lambda trigger. See aws/aws-cdk#7016.',
    }], true);
    postConfirmFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['cognito-idp:AdminUpdateUserAttributes'],
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(postConfirmFn, [{
      id: 'AwsSolutions-IAM5',
      reason: 'Wildcard required to avoid circular dependency between UserPool and Lambda trigger. See aws/aws-cdk#7016.',
    }], true);

    // USER_POOL_ID is NOT passed as env var to avoid circular dependency
    // (lambdaTriggers: UserPool→Lambda, addEnvironment: Lambda→UserPool = cycle).
    // Both Lambdas read event['userPoolId'] at runtime instead — Cognito trigger
    // events always include the UserPool ID.

    // Lambda triggers now handled natively by CDK lambdaTriggers property
    // This eliminates configuration drift and removes ~40 lines of complex custom resource code

    cluster.awsAuth.addRoleMapping(postConfirmFn.role!, {
      groups: ['openclaw:tenant-provisioner'],
      username: 'lambda-post-confirm',
    });

    // RBAC: scoped permissions for PostConfirmation Lambda (not system:masters)
    new eks.KubernetesManifest(this, 'TenantProvisionerRbac', {
      cluster,
      manifest: [
        {
          apiVersion: 'rbac.authorization.k8s.io/v1',
          kind: 'ClusterRole',
          metadata: { name: 'openclaw-tenant-provisioner' },
          rules: [
            { apiGroups: [''], resources: ['namespaces', 'secrets', 'configmaps'], verbs: ['create', 'get', 'list', 'patch', 'update'] },
            { apiGroups: ['argoproj.io'], resources: ['applicationsets', 'applications'], verbs: ['create', 'get', 'list', 'patch', 'update'] },
          ],
        },
        {
          apiVersion: 'rbac.authorization.k8s.io/v1',
          kind: 'ClusterRoleBinding',
          metadata: { name: 'openclaw-tenant-provisioner' },
          roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: 'openclaw-tenant-provisioner' },
          subjects: [{ kind: 'Group', name: 'openclaw:tenant-provisioner', apiGroup: 'rbac.authorization.k8s.io' }],
        },
      ],
      overwrite: true,
    });

    // ── CloudFront WAF (via Custom Resource in us-east-1) ─────────────────
    // CloudFront WAF must be in us-east-1 regardless of stack region.
    // Uses a custom resource (AwsSdkCall) to create/delete the WAF in us-east-1,
    // avoiding cross-region stack dependencies that complicate deployment and deletion.
    const enableBotControl = this.node.tryGetContext('enableBotControl') === true;

    const wafRules: object[] = [
      {
        Name: 'AWSManagedRulesCommonRuleSet',
        Priority: 1,
        OverrideAction: { None: {} },
        Statement: {
          ManagedRuleGroupStatement: { VendorName: 'AWS', Name: 'AWSManagedRulesCommonRuleSet' },
        },
        VisibilityConfig: { CloudWatchMetricsEnabled: true, MetricName: 'CommonRuleSet', SampledRequestsEnabled: true },
      },
      {
        Name: 'RateLimit',
        Priority: 2,
        Action: { Block: {} },
        Statement: { RateBasedStatement: { Limit: 2000, AggregateKeyType: 'IP' } },
        VisibilityConfig: { CloudWatchMetricsEnabled: true, MetricName: 'RateLimit', SampledRequestsEnabled: true },
      },
    ];

    if (enableBotControl) {
      wafRules.push({
        Name: 'AWSManagedRulesBotControlRuleSet',
        Priority: 3,
        OverrideAction: { None: {} },
        Statement: {
          ManagedRuleGroupStatement: {
            VendorName: 'AWS', Name: 'AWSManagedRulesBotControlRuleSet',
            ManagedRuleGroupConfigs: [{ AWSManagedRulesBotControlRuleSet: { InspectionLevel: 'COMMON' } }],
          },
        },
        VisibilityConfig: { CloudWatchMetricsEnabled: true, MetricName: 'BotControl', SampledRequestsEnabled: true },
      });
    }

    const cfWafName = `${this.stackName}-CF-WAF`;

    // CloudFront WAF: if stack is in us-east-1, use native CfnWebACL (simpler, idempotent).
    // If not, use AwsCustomResource to create WAF in us-east-1 via SDK call.
    let cfWafArn: string;

    if (this.region === 'us-east-1') {
      const cfWaf = new wafv2.CfnWebACL(this, 'CloudFrontWaf', {
        defaultAction: { allow: {} },
        scope: 'CLOUDFRONT',
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: 'OpenClawCloudFrontWaf',
          sampledRequestsEnabled: true,
        },
        rules: wafRules.map((r: any) => ({
          name: r.Name, priority: r.Priority,
          ...(r.Action ? { action: { block: {} } } : { overrideAction: { none: {} } }),
          statement: r.Statement.RateBasedStatement
            ? { rateBasedStatement: { limit: r.Statement.RateBasedStatement.Limit, aggregateKeyType: r.Statement.RateBasedStatement.AggregateKeyType } }
            : { managedRuleGroupStatement: { vendorName: r.Statement.ManagedRuleGroupStatement.VendorName, name: r.Statement.ManagedRuleGroupStatement.Name } },
          visibilityConfig: { cloudWatchMetricsEnabled: r.VisibilityConfig.CloudWatchMetricsEnabled, metricName: r.VisibilityConfig.MetricName, sampledRequestsEnabled: r.VisibilityConfig.SampledRequestsEnabled },
        })),
      });
      cfWafArn = cfWaf.attrArn;
    } else {
      const createCfWaf = new cr.AwsCustomResource(this, 'CloudFrontWaf', {
        onCreate: {
          service: 'WAFV2',
          action: 'createWebACL',
          parameters: {
            Name: cfWafName,
            Scope: 'CLOUDFRONT',
            DefaultAction: { Allow: {} },
            VisibilityConfig: { CloudWatchMetricsEnabled: true, MetricName: 'OpenClawCloudFrontWaf', SampledRequestsEnabled: true },
            Rules: wafRules,
          },
          region: 'us-east-1',
          physicalResourceId: cr.PhysicalResourceId.fromResponse('Summary.ARN'),
        },
        // NOTE: No onDelete — WAF deleteWebACL requires LockToken from GetWebACL,
        // which AwsCustomResource cannot chain. force-cleanup.sh handles WAF deletion.
        policy: cr.AwsCustomResourcePolicy.fromStatements([
          new iam.PolicyStatement({
            actions: ['wafv2:CreateWebACL', 'wafv2:GetWebACL'],
            resources: ['*'],
          }),
        ]),
      });
      NagSuppressions.addResourceSuppressions(createCfWaf, [{
        id: 'AwsSolutions-IAM5',
        reason: 'WAF custom resource needs wildcard because WAF ARN is not known at deploy time (created in us-east-1 via SDK call).',
      }], true);
      cfWafArn = createCfWaf.getResponseField('Summary.ARN');
    }

    // S3 bucket for auth UI static site
    const authUiBucket = new s3.Bucket(this, 'AuthUiBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      // Production: add server access logging to a dedicated log bucket
    });

    const oai = new cloudfront.OriginAccessIdentity(this, 'AuthUiOAI');
    authUiBucket.grantRead(oai);

    const distribution = new cloudfront.CloudFrontWebDistribution(this, 'Distribution', {
      // CloudFront WAF (CLOUDFRONT scope, created in us-east-1 via custom resource)
      webACLId: cfWafArn,
      
      ...(useCustomDomain && certificate ? {
        viewerCertificate: cloudfront.ViewerCertificate.fromAcmCertificate(
          acm.Certificate.fromCertificateArn(this, 'CfCert',
            this.node.tryGetContext('cloudfrontCertificateArn') || certificate.certificateArn,
          ),
          {
            aliases: [domainName],
            securityPolicy: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
          },
        ),
      } : {}),
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
      // No errorConfigurations — SPA routing is handled by CloudFront Function
      // on the default behavior. This avoids caching errors from the ALB origin
      // (/t/* behavior) which breaks workspace polling during cold start.
    });

    // CloudFront Function: SPA routing for Auth UI
    // Rewrites paths without file extensions (e.g., /auth/) to /index.html.
    // This replaces errorConfigurations (403/404→index.html) which was
    // distribution-level and interfered with /t/* ALB error responses.
    const spaRewriteFn = new cloudfront.Function(this, 'SpaRewriteFn', {
      code: cloudfront.FunctionCode.fromInline(`
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === '/' || (!uri.includes('.') && !uri.startsWith('/t/'))) {
    request.uri = '/index.html';
  }
  return request;
}
      `.trim()),
    });

    // Attach function to default behavior via L1 (CloudFrontWebDistribution
    // L2 doesn't support function associations directly)
    const cfnDist = distribution.node.defaultChild as cloudfront.CfnDistribution;
    cfnDist.addPropertyOverride(
      'DistributionConfig.DefaultCacheBehavior.FunctionAssociations',
      [{ EventType: 'viewer-request', FunctionARN: spaRewriteFn.functionArn }],
    );

    // ── Auth UI: Deploy static files + generate config.js ───────────────────
    // Auth UI: deploy static files only. config.js is generated by deploy-auth-ui.sh
    // from stack outputs (Cognito Pool ID, Client ID, domain) to avoid circular dependency.
    const authDomain = useCustomDomain ? domainName : distribution.distributionDomainName;

    new s3deploy.BucketDeployment(this, 'AuthUiDeployment', {
      sources: [
        s3deploy.Source.asset('../auth-ui'),
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
        CERTIFICATE_ARN: certificate?.certificateArn || '',
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
      // Wildcard required: CostEnforcer scans all tenant secrets to read
      // per-tenant budget tags. Cannot scope to specific ARNs because tenant
      // secrets are created dynamically by PostConfirmation Lambda.
      resources: ['*'],
    }));
    NagSuppressions.addResourceSuppressions(costEnforcerFn, [{
      id: 'AwsSolutions-IAM5',
      reason: 'CostEnforcer Lambda needs ListSecrets/DescribeSecret across all tenant secrets to read budget tags. Tenant secrets are created dynamically; ARNs not known at deploy time.',
    }], true);

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
    new cdk.CfnOutput(this, 'DomainName', { value: useCustomDomain ? domainName : distribution.distributionDomainName });
    new cdk.CfnOutput(this, 'CustomDomain', { value: useCustomDomain ? 'true' : 'false' });
    new cdk.CfnOutput(this, 'CertificateArn', { value: certificate?.certificateArn || '' });
    new cdk.CfnOutput(this, 'CognitoPoolId', { value: userPool.userPoolId });
    new cdk.CfnOutput(this, 'CognitoClientId', { value: userPoolClient.userPoolClientId });
    new cdk.CfnOutput(this, 'CognitoDomain', { value: cognitoDomainPrefix });
    new cdk.CfnOutput(this, 'AlertsTopicArn', { value: alertsTopic.topicArn });
    new cdk.CfnOutput(this, 'PreSignupFnArn', { value: preSignupFn.functionArn });
    new cdk.CfnOutput(this, 'PostConfirmFnArn', { value: postConfirmFn.functionArn });
    new cdk.CfnOutput(this, 'AuthUiBucketName', { value: authUiBucket.bucketName });
    new cdk.CfnOutput(this, 'DistributionDomainName', { value: distribution.distributionDomainName });
    new cdk.CfnOutput(this, 'CloudFrontWafArn', { value: cfWafArn });
    new cdk.CfnOutput(this, 'CloudFrontCertificateArn', { value: this.node.tryGetContext('cloudfrontCertificateArn') || '' });
    new cdk.CfnOutput(this, 'OpenClawImageUri', { value: openclawImage });
    new cdk.CfnOutput(this, 'GithubOwner', { value: githubOwner || 'aws-samples' });
    new cdk.CfnOutput(this, 'GithubRepo', { value: githubRepo || 'openclaw-platform' });

    // ── cdk-nag Stack-Level Suppressions ────────────────────────────────────
    // These are acceptable trade-offs for a sample project. Production deployments
    // should address each finding individually. See docs/security.md for details.
    const nagSuppressions = [
      { id: 'AwsSolutions-IAM4', reason: 'AWS managed policies are appropriate for EKS add-on roles and CDK provider Lambdas.' },
      { id: 'AwsSolutions-IAM5', reason: 'Wildcard permissions documented inline. CDK EKS provider framework uses wildcards internally.' },
      { id: 'AwsSolutions-L1', reason: 'Lambda runtime Python 3.12 is current. CDK provider Lambdas use CDK-managed runtimes.' },
      { id: 'AwsSolutions-S1', reason: 'S3 access logging omitted for sample cost. See security.md Production Hardening.' },
      { id: 'AwsSolutions-SQS4', reason: 'DLQ is internal (Lambda async failures only). SSL enforcement is production hardening.' },
      { id: 'AwsSolutions-COG1', reason: 'Password policy: 12 chars, upper/lower/digits. Symbols omitted for sample UX.' },
      { id: 'AwsSolutions-COG2', reason: 'MFA omitted for sample simplicity. See security.md Production Hardening.' },
      { id: 'AwsSolutions-COG3', reason: 'AdvancedSecurityMode adds cost. See security.md Production Hardening.' },
      { id: 'AwsSolutions-CFR1', reason: 'Geo restrictions not needed for sample.' },
      { id: 'AwsSolutions-CFR3', reason: 'CloudFront access logging omitted for sample cost.' },
      { id: 'AwsSolutions-CFR4', reason: 'No-domain mode uses default CloudFront cert (TLSv1). Custom domain mode uses TLSv1.2.' },
      { id: 'AwsSolutions-CFR7', reason: 'Using OAI for CloudFrontWebDistribution. OAC requires Distribution L2 migration.' },
      { id: 'AwsSolutions-EC23', reason: 'ALB SG restricted to CloudFront prefix list IPs, not 0.0.0.0/0.' },
      { id: 'AwsSolutions-EKS1', reason: 'EKS public endpoint for kubectl access. See security.md.' },
      { id: 'AwsSolutions-SF1', reason: 'CDK EKS provider Step Functions — not user-controlled.' },
      { id: 'AwsSolutions-SF2', reason: 'CDK EKS provider Step Functions — not user-controlled.' },
    ];
    NagSuppressions.addStackSuppressions(this, nagSuppressions, true);
  }
}
