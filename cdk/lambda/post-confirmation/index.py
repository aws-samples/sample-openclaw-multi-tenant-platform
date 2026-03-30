import os
import re
import json
import secrets
import urllib.request
import boto3
from botocore.exceptions import ClientError

eks_client = boto3.client('eks')
sns = boto3.client('sns')
sts = boto3.client('sts')
sm = boto3.client('secretsmanager')
cognito = boto3.client('cognito-idp')

TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
CLUSTER_NAME = os.environ['CLUSTER_NAME']
TENANT_ROLE_ARN = os.environ['TENANT_ROLE_ARN']
DOMAIN = os.environ.get('DOMAIN', 'example.com')
REGION = os.environ.get('AWS_REGION', 'us-west-2')
USER_POOL_ID = os.environ['USER_POOL_ID']


def get_eks_token():
    """Generate EKS bearer token using STS presigned URL."""
    import base64
    from botocore.signers import RequestSigner
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
    signed_url = signer.generate_presigned_url(params, region_name=REGION, expires_in=60, operation_name='')
    return 'k8s-aws-v1.' + base64.urlsafe_b64encode(signed_url.encode()).decode().rstrip('=')


def create_tenant_cr(tenant, email):
    """Create a Tenant CR via K8s API (single attempt, must complete within Cognito 5s limit)."""
    return _create_tenant_cr_inner(tenant, email)


def _create_tenant_cr_inner(tenant, email):
    import base64
    cluster = eks_client.describe_cluster(name=CLUSTER_NAME)['cluster']
    endpoint = cluster['endpoint']
    ca_data = cluster['certificateAuthority']['data']

    tenant_cr = json.dumps({
        "apiVersion": "openclaw.io/v1alpha1",
        "kind": "Tenant",
        "metadata": {"name": tenant, "namespace": "openclaw-system"},
        "spec": {
            "email": email,
            "displayName": "OpenClaw",
            "emoji": "",
            "skills": ["weather", "gog"],
            "budget": {"monthlyUSD": 100},
            "enabled": True,
        }
    }).encode()

    import ssl, tempfile
    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix='.crt')
    ca_file.write(base64.b64decode(ca_data))
    ca_file.close()
    ctx = ssl.create_default_context(cafile=ca_file.name)

    url = f"{endpoint}/apis/openclaw.io/v1alpha1/namespaces/openclaw-system/tenants/{tenant}"
    bearer = get_eks_token()

    # Try PUT (update), fall back to POST (create)
    for method in ['PUT', 'POST']:
        req_url = url if method == 'PUT' else f"{endpoint}/apis/openclaw.io/v1alpha1/namespaces/openclaw-system/tenants"
        req = urllib.request.Request(req_url, data=tenant_cr, method=method,
            headers={'Authorization': f'Bearer {bearer}', 'Content-Type': 'application/json'})
        try:
            urllib.request.urlopen(req, context=ctx)
            return
        except urllib.error.HTTPError as e:
            if method == 'PUT' and e.code == 404:
                continue  # Not found, try POST
            if e.code == 409:
                return  # Already exists
            raise


def handler(event, context):
    email = event['request']['userAttributes']['email']
    local = email.split('@')[0].lower()
    tenant = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    ns = f'openclaw-{tenant}'

    # 1. Pod Identity Association
    try:
        eks_client.create_pod_identity_association(
            clusterName=CLUSTER_NAME, namespace=ns,
            serviceAccount=f'{tenant}-openclaw-helm', roleArn=TENANT_ROLE_ARN,
        )
    except ClientError as e:
        if 'already exists' not in str(e).lower():
            raise

    # 2. Validate tenant name (defense in depth)
    if not tenant or len(tenant) > 63 or not all(c.isalnum() or c == '-' for c in tenant):
        raise Exception(f'Invalid tenant name: {tenant}')

    # 3. Gateway token → SM + Cognito attribute
    username = event['userName']
    token = secrets.token_urlsafe(32)
    secret_name = f'openclaw/{tenant}/gateway-token'
    try:
        sm.create_secret(Name=secret_name, SecretString=token,
                         Tags=[{'Key': 'tenant', 'Value': tenant}])
    except ClientError as e:
        code = e.response['Error']['Code']
        if code == 'InvalidRequestException':
            sm.restore_secret(SecretId=secret_name)
            sm.update_secret(SecretId=secret_name, SecretString=token)
        elif code == 'ResourceExistsException':
            sm.update_secret(SecretId=secret_name, SecretString=token)
        else:
            raise
    cognito.admin_update_user_attributes(
        UserPoolId=USER_POOL_ID, Username=username,
        UserAttributes=[{'Name': 'custom:gateway_token', 'Value': token}])

    # 4. Create Tenant CR → Operator handles the rest
    create_tenant_cr(tenant, email)

    # 5. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN, Subject='New Tenant Created',
        Message=f'Tenant: {tenant} ({email})\nURL: https://{DOMAIN}/t/{tenant}',
    )

    return event
