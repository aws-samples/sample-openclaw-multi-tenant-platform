import os
import re
import json
import base64
import secrets
import urllib.request
import urllib.parse
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

ALLOWED_URL_SCHEMES = {'https'}


def _validate_url(url):
    """Validate URL scheme is in the allowlist."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ALLOWED_URL_SCHEMES:
        raise ValueError(f'URL scheme {parsed.scheme!r} not allowed, must be one of {ALLOWED_URL_SCHEMES}')


def _get_eks_context():
    """Get EKS endpoint, CA cert SSL context, and bearer token."""
    import ssl
    import tempfile
    cluster = eks_client.describe_cluster(name=CLUSTER_NAME)['cluster']
    endpoint = cluster['endpoint']
    ca_data = cluster['certificateAuthority']['data']
    _validate_url(endpoint)

    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix='.crt')
    ca_file.write(base64.b64decode(ca_data))
    ca_file.close()
    ctx = ssl.create_default_context(cafile=ca_file.name)

    return endpoint, ctx, get_eks_token()


def get_eks_token():
    """Generate EKS bearer token using STS presigned URL."""
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


def _k8s_apply(endpoint, ssl_ctx, bearer, url, body):
    """Apply a K8s resource using server-side apply (PATCH).

    Server-side apply avoids the 422 error from PUT without resourceVersion
    on existing resources, and handles create-or-update in a single call.
    """
    _validate_url(url)
    data = json.dumps(body).encode()
    req = urllib.request.Request(url + '?fieldManager=post-confirmation-lambda&force=true',
        data=data, method='PATCH',
        headers={
            'Authorization': f'Bearer {bearer}',
            'Content-Type': 'application/apply-patch+yaml',
        })
    try:
        urllib.request.urlopen(req, context=ssl_ctx)  # nosemgrep: dynamic-urllib-use-detected  # noqa: B310 -- URL scheme validated by _validate_url()
    except urllib.error.HTTPError as e:
        if e.code == 409:
            return  # Conflict, resource exists with different field manager -- acceptable
        raise


def _k8s_get(endpoint, ssl_ctx, bearer, url):
    """GET a K8s resource. Returns parsed JSON or None if 404."""
    _validate_url(url)
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {bearer}'})
    try:
        resp = urllib.request.urlopen(req, context=ssl_ctx)  # nosemgrep: dynamic-urllib-use-detected  # noqa: B310 -- URL scheme validated by _validate_url()
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def _resolve_tenant_name(base_name, email):
    """Resolve a unique tenant name by checking existing Tenant CRs.

    If base_name is not taken (or is owned by the same email), return it.
    Otherwise, append -2, -3, ... up to -9 to find a free name.
    Raises if no free name found within 9 attempts.
    """
    endpoint, ssl_ctx, bearer = _get_eks_context()

    for suffix in ['', '-2', '-3', '-4', '-5', '-6', '-7', '-8', '-9']:
        candidate = f'{base_name}{suffix}'[:63]  # K8s name limit
        url = f"{endpoint}/apis/openclaw.io/v1alpha1/namespaces/openclaw-system/tenants/{candidate}"
        existing = _k8s_get(endpoint, ssl_ctx, bearer, url)
        if existing is None:
            return candidate  # Name is free
        existing_email = existing.get('spec', {}).get('email', '')
        if existing_email == email:
            return candidate  # Same user re-confirming, reuse existing tenant
    raise Exception(f'Could not find a unique tenant name for {base_name} after 9 attempts')


def create_tenant_cr(tenant, email):
    """Create a Tenant CR via K8s API."""
    endpoint, ssl_ctx, bearer = _get_eks_context()
    url = f"{endpoint}/apis/openclaw.io/v1alpha1/namespaces/openclaw-system/tenants/{tenant}"
    body = {
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
    }
    _k8s_apply(endpoint, ssl_ctx, bearer, url, body)


def create_gateway_secret(tenant, ns, token):
    """Create K8s Secret with gateway token so pod and auth-ui use the same token."""
    endpoint, ssl_ctx, bearer = _get_eks_context()
    secret_name = f"{tenant}-gateway-token"
    url = f"{endpoint}/api/v1/namespaces/{ns}/secrets/{secret_name}"
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": secret_name,
            "namespace": ns,
            "labels": {"app.kubernetes.io/managed-by": "post-confirmation-lambda"},
        },
        "type": "Opaque",
        "data": {
            "OPENCLAW_GATEWAY_TOKEN": base64.b64encode(token.encode()).decode(),
        }
    }
    _k8s_apply(endpoint, ssl_ctx, bearer, url, body)


def handler(event, context):
    email = event['request']['userAttributes']['email']
    local = email.split('@')[0].lower()
    base_name = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')

    # 1. Validate base tenant name (defense in depth)
    if not base_name or len(base_name) > 63 or not all(c.isalnum() or c == '-' for c in base_name):
        raise Exception(f'Invalid tenant name: {base_name}')

    # 2. Resolve unique tenant name (check for collisions)
    tenant = _resolve_tenant_name(base_name, email)
    ns = f'openclaw-{tenant}'

    # 3. Pod Identity Association
    try:
        eks_client.create_pod_identity_association(
            clusterName=CLUSTER_NAME, namespace=ns,
            serviceAccount=f'{tenant}', roleArn=TENANT_ROLE_ARN,
        )
    except ClientError as e:
        if 'already exists' not in str(e).lower():
            raise

    # 4. Gateway token -> SM + Cognito attribute + K8s Secret
    username = event['userName']
    token = secrets.token_urlsafe(32)
    secret_name = f'openclaw/{tenant}/gateway-token'
    try:
        sm.create_secret(Name=secret_name, SecretString=token,
                         Tags=[{'Key': 'tenant', 'Value': tenant},
                               {'Key': 'tenant-namespace', 'Value': ns}])
    except ClientError as e:
        code = e.response['Error']['Code']
        if code == 'InvalidRequestException':
            sm.restore_secret(SecretId=secret_name)
            sm.update_secret(SecretId=secret_name, SecretString=token)
        elif code == 'ResourceExistsException':
            sm.update_secret(SecretId=secret_name, SecretString=token)
        else:
            raise

    # 5. Store tenant name in Cognito so frontend can look it up on sign-in
    cognito.admin_update_user_attributes(
        UserPoolId=USER_POOL_ID, Username=username,
        UserAttributes=[
            {'Name': 'custom:gateway_token', 'Value': token},
            {'Name': 'custom:tenant_name', 'Value': tenant},
        ])

    # 6. Create Tenant CR -> Operator handles the rest
    create_tenant_cr(tenant, email)

    # 7. Create K8s Secret with gateway token (single source of truth from SM)
    create_gateway_secret(tenant, ns, token)

    # 8. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN, Subject='New Tenant Created',
        Message=f'Tenant: {tenant} ({email})\nURL: https://{DOMAIN}/t/{tenant}',
    )

    return event
