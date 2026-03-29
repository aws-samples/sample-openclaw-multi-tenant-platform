import os
import re
import json
import secrets
import base64
import urllib.request
import boto3
from botocore.exceptions import ClientError

sm = boto3.client('secretsmanager')
eks_client = boto3.client('eks')
sns = boto3.client('sns')
cognito = boto3.client('cognito-idp')
sts = boto3.client('sts')

TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
CLUSTER_NAME = os.environ['CLUSTER_NAME']
TENANT_ROLE_ARN = os.environ['TENANT_ROLE_ARN']
DOMAIN = os.environ.get('DOMAIN', 'example.com')
COGNITO_POOL_ID = os.environ.get('COGNITO_POOL_ID', '')
ALB_CLIENT_ID = os.environ.get('ALB_CLIENT_ID', '')
CERTIFICATE_ARN = os.environ.get('CERTIFICATE_ARN', '')
COGNITO_DOMAIN = os.environ.get('COGNITO_DOMAIN', '')
REGION = os.environ.get('AWS_REGION', 'us-west-2')


def get_eks_token():
    """Generate EKS bearer token using STS presigned URL."""
    from botocore.signers import RequestSigner
    STS_TOKEN_EXPIRES_IN = 60
    session = boto3.session.Session()
    client = session.client('sts', region_name=REGION)
    service_id = client.meta.service_model.service_id
    signer = RequestSigner(service_id, REGION, 'sts', 'v4', session.get_credentials(), session.events)
    params = {
        'method': 'GET',
        'url': f'https://sts.{REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15',
        'body': {},
        'headers': {'x-k8s-aws-id': CLUSTER_NAME},
        'context': {},
    }
    signed_url = signer.generate_presigned_url(params, region_name=REGION, expires_in=STS_TOKEN_EXPIRES_IN, operation_name='')
    return 'k8s-aws-v1.' + base64.urlsafe_b64encode(signed_url.encode()).decode().rstrip('=')


def get_k8s_client():
    """Get authenticated K8s client using EKS token."""
    from kubernetes import client as k8s_client
    import tempfile

    cluster = eks_client.describe_cluster(name=CLUSTER_NAME)['cluster']
    endpoint = cluster['endpoint']
    ca_data = cluster['certificateAuthority']['data']

    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix='.crt')
    ca_file.write(base64.b64decode(ca_data))
    ca_file.close()

    config = k8s_client.Configuration()
    config.host = endpoint
    config.ssl_ca_cert = ca_file.name
    config.api_key = {'authorization': f'Bearer {get_eks_token()}'}

    return k8s_client.ApiClient(config)


def apply_k8s_manifests(tenant, ns, gateway_token):
    """Create namespace + all K8s resources directly via API."""
    from kubernetes import client as k8s_client

    api_client = get_k8s_client()
    core = k8s_client.CoreV1Api(api_client)
    apps = k8s_client.AppsV1Api(api_client)
    networking = k8s_client.NetworkingV1Api(api_client)

    labels = {
        'app.kubernetes.io/name': 'openclaw-helm',
        'app.kubernetes.io/instance': f'openclaw-{tenant}',
        'tenant': tenant,
    }

    # 1. Namespace
    try:
        core.create_namespace(body=k8s_client.V1Namespace(
            metadata=k8s_client.V1ObjectMeta(name=ns, labels={'name': ns}),
        ))
    except k8s_client.exceptions.ApiException as e:
        if e.status != 409:
            raise

    # 2. ServiceAccount
    try:
        core.create_namespaced_service_account(ns, body=k8s_client.V1ServiceAccount(
            metadata=k8s_client.V1ObjectMeta(name=f'openclaw-{tenant}', namespace=ns, labels=labels),
        ))
    except k8s_client.exceptions.ApiException as e:
        if e.status != 409:
            raise

    # 3. Secret (gateway token)
    try:
        core.create_namespaced_secret(ns, body=k8s_client.V1Secret(
            metadata=k8s_client.V1ObjectMeta(
                name=f'openclaw-{tenant}-gateway-token',
                namespace=ns,
                labels=labels,
                annotations={'helm.sh/resource-policy': 'keep'},
            ),
            string_data={'GATEWAY_TOKEN': gateway_token},
        ))
    except k8s_client.exceptions.ApiException as e:
        if e.status != 409:
            raise

    # 4. Service
    try:
        core.create_namespaced_service(ns, body=k8s_client.V1Service(
            metadata=k8s_client.V1ObjectMeta(name=f'openclaw-{tenant}', namespace=ns, labels=labels),
            spec=k8s_client.V1ServiceSpec(
                selector=labels,
                ports=[k8s_client.V1ServicePort(port=18789, target_port=18789, protocol='TCP')],
            ),
        ))
    except k8s_client.exceptions.ApiException as e:
        if e.status != 409:
            raise

    # 5. Deployment
    container = k8s_client.V1Container(
        name='openclaw',
        image=os.environ.get('OPENCLAW_IMAGE', 'ghcr.io/openclaw/openclaw:latest'),
        ports=[k8s_client.V1ContainerPort(container_port=18789)],
        env_from=[k8s_client.V1EnvFromSource(
            secret_ref=k8s_client.V1SecretEnvSource(name=f'openclaw-{tenant}-gateway-token'),
        )],
        resources=k8s_client.V1ResourceRequirements(
            requests={'cpu': '250m', 'memory': '512Mi'},
            limits={'cpu': '2', 'memory': '2Gi'},
        ),
    )
    deployment = k8s_client.V1Deployment(
        metadata=k8s_client.V1ObjectMeta(name=f'openclaw-{tenant}', namespace=ns, labels=labels),
        spec=k8s_client.V1DeploymentSpec(
            replicas=1,
            selector=k8s_client.V1LabelSelector(match_labels=labels),
            template=k8s_client.V1PodTemplateSpec(
                metadata=k8s_client.V1ObjectMeta(labels=labels),
                spec=k8s_client.V1PodSpec(
                    service_account_name=f'openclaw-{tenant}',
                    containers=[container],
                ),
            ),
        ),
    )
    try:
        apps.create_namespaced_deployment(ns, body=deployment)
    except k8s_client.exceptions.ApiException as e:
        if e.status == 409:
            apps.replace_namespaced_deployment(f'openclaw-{tenant}', ns, body=deployment)
        else:
            raise

    # 6. Ingress
    cognito_json = json.dumps({
        'userPoolARN': f'arn:aws:cognito-idp:{REGION}:{sts.get_caller_identity()["Account"]}:userpool/{COGNITO_POOL_ID}',
        'userPoolClientID': ALB_CLIENT_ID,
        'userPoolDomain': COGNITO_DOMAIN,
    })
    ingress = k8s_client.V1Ingress(
        metadata=k8s_client.V1ObjectMeta(
            name=f'openclaw-{tenant}',
            namespace=ns,
            labels=labels,
            annotations={
                'alb.ingress.kubernetes.io/scheme': 'internal',
                'alb.ingress.kubernetes.io/target-type': 'ip',
                'alb.ingress.kubernetes.io/group.name': 'openclaw-shared',
                'alb.ingress.kubernetes.io/listen-ports': '[{"HTTPS":443}]',
                'alb.ingress.kubernetes.io/ssl-redirect': '443',
                'alb.ingress.kubernetes.io/certificate-arn': CERTIFICATE_ARN,
                'alb.ingress.kubernetes.io/auth-type': 'cognito',
                'alb.ingress.kubernetes.io/auth-idp-cognito': cognito_json,
                'alb.ingress.kubernetes.io/auth-on-unauthenticated-request': 'authenticate',
                'alb.ingress.kubernetes.io/auth-scope': 'openid email profile',
                'alb.ingress.kubernetes.io/auth-session-timeout': '604800',
            },
        ),
        spec=k8s_client.V1IngressSpec(
            ingress_class_name='alb',
            rules=[k8s_client.V1IngressRule(
                host=f'{tenant}.{DOMAIN}',
                http=k8s_client.V1HTTPIngressRuleValue(paths=[
                    k8s_client.V1HTTPIngressPath(
                        path='/',
                        path_type='Prefix',
                        backend=k8s_client.V1IngressBackend(
                            service=k8s_client.V1IngressServiceBackend(
                                name=f'openclaw-{tenant}',
                                port=k8s_client.V1ServiceBackendPort(number=18789),
                            ),
                        ),
                    ),
                ]),
            )],
        ),
    )
    try:
        networking.create_namespaced_ingress(ns, body=ingress)
    except k8s_client.exceptions.ApiException as e:
        if e.status == 409:
            networking.replace_namespaced_ingress(f'openclaw-{tenant}', ns, body=ingress)
        else:
            raise


def handler(event, context):
    email = event['request']['userAttributes']['email']
    local = email.split('@')[0].lower()
    tenant = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    ns = f'openclaw-{tenant}'

    # 1. Gateway token in Secrets Manager
    token = secrets.token_urlsafe(32)
    secret_name = f'openclaw/{tenant}/gateway-token'
    try:
        sm.create_secret(
            Name=secret_name, SecretString=token,
            Tags=[{'Key': 'tenant-namespace', 'Value': ns}],
        )
    except ClientError as e:
        code = e.response['Error']['Code']
        if code == 'ResourceExistsException':
            token = sm.get_secret_value(SecretId=secret_name)['SecretString']
        elif code == 'InvalidRequestException' and 'scheduled for deletion' in str(e):
            sm.restore_secret(SecretId=secret_name)
            sm.update_secret(SecretId=secret_name, SecretString=token)
        else:
            raise

    # 2. Pod Identity Association
    try:
        eks_client.create_pod_identity_association(
            clusterName=CLUSTER_NAME,
            namespace=ns,
            serviceAccount=f'openclaw-{tenant}',
            roleArn=TENANT_ROLE_ARN,
        )
    except ClientError as e:
        if 'already exists' not in str(e).lower():
            raise

    # 3. Cognito callback URL (ALB client)
    try:
        client_info = cognito.describe_user_pool_client(
            UserPoolId=COGNITO_POOL_ID, ClientId=ALB_CLIENT_ID,
        )['UserPoolClient']
        callbacks = client_info.get('CallbackURLs', [])
        new_cb = f'https://{tenant}.{DOMAIN}/oauth2/idpresponse'
        if new_cb not in callbacks:
            callbacks.append(new_cb)
            cognito.update_user_pool_client(
                UserPoolId=COGNITO_POOL_ID,
                ClientId=ALB_CLIENT_ID,
                CallbackURLs=callbacks,
                ExplicitAuthFlows=client_info.get('ExplicitAuthFlows', []),
                AllowedOAuthFlows=client_info.get('AllowedOAuthFlows', []),
                AllowedOAuthScopes=client_info.get('AllowedOAuthScopes', []),
                AllowedOAuthFlowsUserPoolClient=True,
                SupportedIdentityProviders=client_info.get('SupportedIdentityProviders', []),
            )
    except ClientError:
        pass  # Non-fatal

    # 4. K8s resources (namespace + SA + secret + service + deployment + ingress)
    apply_k8s_manifests(tenant, ns, token)

    # 5. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject='New Tenant Created',
        Message=f'Tenant: {tenant} ({email})\nURL: https://{tenant}.{DOMAIN}',
    )

    return event
