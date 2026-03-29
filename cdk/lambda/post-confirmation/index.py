import os
import re
import secrets
import boto3
from botocore.exceptions import ClientError

sm = boto3.client('secretsmanager')
eks_client = boto3.client('eks')
sns = boto3.client('sns')
cb = boto3.client('codebuild')

TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
CLUSTER_NAME = os.environ['CLUSTER_NAME']
TENANT_ROLE_ARN = os.environ['TENANT_ROLE_ARN']
DOMAIN = os.environ.get('DOMAIN', 'example.com')
CODEBUILD_PROJECT = os.environ.get('CODEBUILD_PROJECT', 'openclaw-tenant-builder')

def handler(event, context):
    email = event['request']['userAttributes']['email']
    local = email.split('@')[0].lower()
    tenant = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    ns = f'openclaw-{tenant}'

    # 1. Gateway token secret (skip if exists)
    try:
        token = secrets.token_urlsafe(32)
        sm.create_secret(
            Name=f'openclaw/{tenant}/gateway-token',
            SecretString=token,
            Tags=[{'Key': 'tenant-namespace', 'Value': ns}],
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceExistsException':
            pass  # Already exists, skip
        else:
            raise

    # 2. Pod Identity Association (skip if exists)
    try:
        eks_client.create_pod_identity_association(
            clusterName=CLUSTER_NAME,
            namespace=ns,
            serviceAccount=f'openclaw-{tenant}',
            roleArn=TENANT_ROLE_ARN,
        )
    except ClientError as e:
        if 'already exists' in str(e).lower():
            pass
        else:
            raise

    # 3. Trigger CodeBuild (always — idempotent)
    try:
        cb.start_build(
            projectName=CODEBUILD_PROJECT,
            environmentVariablesOverride=[
                {'name': 'TENANT_NAME', 'value': tenant, 'type': 'PLAINTEXT'},
            ],
        )
    except ClientError:
        pass  # CodeBuild failure is non-fatal — admin can run create-tenant.sh manually

    # 4. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject='New Tenant Created',
        Message=f'Tenant: {tenant} ({email})\nURL: https://{tenant}.{DOMAIN}',
    )

    return event
