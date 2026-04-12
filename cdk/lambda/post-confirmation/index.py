import os
import re
import json
import base64
import logging
import secrets
import ssl
import time
import urllib.request
import urllib.parse
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

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
# USER_POOL_ID is read from event['userPoolId'] at runtime to avoid
# circular dependency between UserPool and Lambda trigger in CDK.

ALLOWED_URL_SCHEMES = {'https'}

# Cache EKS context within a single Lambda invocation.
# - endpoint + CA cert don't change within an invocation
# - EKS bearer token is valid for ~15 minutes (presigned STS GetCallerIdentity URL)
#   ref: https://docs.aws.amazon.com/eks/latest/userguide/cluster-auth.html
# - Lambda max timeout is 60s, well within token validity
# - Saves ~1s per call (DescribeCluster + STS token generation) × 3 calls = ~3s
_eks_context_cache = None


def _validate_url(url):
    """Validate URL scheme is in the allowlist."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ALLOWED_URL_SCHEMES:
        raise ValueError(f'URL scheme {parsed.scheme!r} not allowed, must be one of {ALLOWED_URL_SCHEMES}')


def _get_eks_context():
    """Get EKS endpoint, CA cert SSL context, and bearer token.

    Results are cached for the duration of the Lambda invocation.
    The EKS bearer token (presigned STS URL) is valid for ~15 minutes,
    so reuse within a single invocation (max 60s) is safe.
    """
    global _eks_context_cache
    if _eks_context_cache is not None:
        return _eks_context_cache

    import tempfile
    cluster = eks_client.describe_cluster(name=CLUSTER_NAME)['cluster']
    endpoint = cluster['endpoint']
    ca_data = cluster['certificateAuthority']['data']
    _validate_url(endpoint)

    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix='.crt')
    ca_file.write(base64.b64decode(ca_data))
    ca_file.close()
    ctx = ssl.create_default_context(cafile=ca_file.name)

    _eks_context_cache = (endpoint, ctx, get_eks_token())
    return _eks_context_cache


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
        urllib.request.urlopen(req, context=ssl_ctx)  # nosemgrep: dynamic-urllib-use-detected  # noqa: B310  # nosec B310 -- URL scheme validated by _validate_url()
    except urllib.error.HTTPError as e:
        if e.code == 409:
            return  # Conflict, resource exists with different field manager -- acceptable
        raise


def _k8s_get(endpoint, ssl_ctx, bearer, url):
    """GET a K8s resource. Returns parsed JSON or None if 404."""
    _validate_url(url)
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {bearer}'})
    try:
        resp = urllib.request.urlopen(req, context=ssl_ctx)  # nosemgrep: dynamic-urllib-use-detected  # noqa: B310  # nosec B310 -- URL scheme validated by _validate_url()
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def _resolve_tenant_name(base_name, email):
    """Resolve a unique tenant name by checking ApplicationSet elements.

    If base_name is not taken (or is owned by the same email), return it.
    Otherwise, append -2, -3, ... up to -9 to find a free name.
    Raises if no free name found within 9 attempts.
    """
    endpoint, ssl_ctx, bearer = _get_eks_context()
    appset = _k8s_get(endpoint, ssl_ctx, bearer,
        f"{endpoint}/apis/argoproj.io/v1alpha1/namespaces/argocd/applicationsets/openclaw-tenants")
    try:
        elements = appset.get('spec', {}).get('generators', [{}])[0].get('list', {}).get('elements', []) if appset else []
        taken = {e['name']: e.get('email', '') for e in elements if 'name' in e}
    except (KeyError, IndexError, TypeError):
        taken = {}

    for suffix in ['', '-2', '-3', '-4', '-5', '-6', '-7', '-8', '-9']:
        candidate = f'{base_name}{suffix}'[:63]
        if candidate not in taken:
            return candidate
        if taken[candidate] == email:
            return candidate  # Same user re-confirming
    raise Exception(f'Could not find a unique tenant name for {base_name} after 9 attempts')


def add_tenant_to_applicationset(tenant, email):
    """Add a tenant element to the ApplicationSet via K8s API (read-modify-write)."""
    endpoint, ssl_ctx, bearer = _get_eks_context()
    url = f"{endpoint}/apis/argoproj.io/v1alpha1/namespaces/argocd/applicationsets/openclaw-tenants"

    for attempt in range(3):
        appset = _k8s_get(endpoint, ssl_ctx, bearer, url)
        if not appset:
            raise Exception('ApplicationSet openclaw-tenants not found in argocd namespace')

        elements = appset.get('spec', {}).get('generators', [{}])[0].get('list', {}).get('elements', [])

        # Idempotent: skip if tenant already exists
        if any(e.get('name') == tenant for e in elements):
            return

        elements.append({'name': tenant, 'email': email})
        try:
            appset['spec']['generators'][0]['list']['elements'] = elements
        except (KeyError, IndexError, TypeError) as e:
            raise Exception(f'ApplicationSet has unexpected structure: {e}')

        # PUT with resourceVersion for optimistic locking
        _validate_url(url)
        data = json.dumps(appset).encode()
        req = urllib.request.Request(url, data=data, method='PUT',
            headers={'Authorization': f'Bearer {bearer}', 'Content-Type': 'application/json'})
        try:
            urllib.request.urlopen(req, context=ssl_ctx)  # nosemgrep: dynamic-urllib-use-detected  # noqa: B310  # nosec B310
            return
        except urllib.error.HTTPError as e:
            if e.code == 409 and attempt < 2:  # Conflict — retry with fresh resourceVersion
                continue
            raise


def _ensure_namespace(tenant, ns):
    """Create namespace if it doesn't exist. ArgoCD adopts it via server-side apply."""
    endpoint, ssl_ctx, bearer = _get_eks_context()
    url = f"{endpoint}/api/v1/namespaces/{ns}"
    body = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": ns,
            "labels": {
                "app.kubernetes.io/managed-by": "post-confirmation-lambda",
                "openclaw.io/tenant": tenant,
            },
        },
    }
    _k8s_apply(endpoint, ssl_ctx, bearer, url, body)
    logger.info('Namespace %s ensured', ns)


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
    # Reset EKS context cache for each invocation.
    # Token is valid ~15 min but Lambda containers can be reused for hours.
    # Cache only saves repeated calls within a single invocation.
    global _eks_context_cache
    _eks_context_cache = None

    user_pool_id = event['userPoolId']
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
        UserPoolId=user_pool_id, Username=username,
        UserAttributes=[
            {'Name': 'custom:gateway_token', 'Value': token},
            {'Name': 'custom:tenant_name', 'Value': tenant},
        ])

    # 6. Create namespace first (before ApplicationSet) to avoid race condition.
    # ArgoCD will adopt the existing namespace via server-side apply.
    _ensure_namespace(tenant, ns)

    # 7. Create K8s Secret with gateway token (namespace exists from step 6)
    create_gateway_secret(tenant, ns, token)

    # 8. Add tenant to ApplicationSet -> ArgoCD creates Application -> Helm syncs resources
    # Namespace and secret already exist — ArgoCD adopts them.
    add_tenant_to_applicationset(tenant, email)

    # 9. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN, Subject='New Tenant Created',
        Message=f'Tenant: {tenant} ({email})\nURL: https://{DOMAIN}/t/{tenant}',
    )

    return event
