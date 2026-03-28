import os
import re
import secrets
import boto3

sm = boto3.client('secretsmanager')
eks_client = boto3.client('eks')
sns = boto3.client('sns')
ses = boto3.client('ses')
cb = boto3.client('codebuild')

TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
CLUSTER_NAME = os.environ['CLUSTER_NAME']
TENANT_ROLE_ARN = os.environ['TENANT_ROLE_ARN']
DOMAIN = os.environ.get('DOMAIN', '<YOUR_DOMAIN>')
CODEBUILD_PROJECT = os.environ.get('CODEBUILD_PROJECT', 'openclaw-tenant-builder')

def handler(event, context):
    email = event['request']['userAttributes']['email']
    local = email.split('@')[0].lower()
    tenant = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    ns = f'openclaw-{tenant}'

    # 1. Gateway token secret
    token = secrets.token_urlsafe(32)
    sm.create_secret(
        Name=f'openclaw/{tenant}/gateway-token',
        SecretString=token,
        Tags=[{'Key': 'tenant-namespace', 'Value': ns}],
    )

    # 2. Pod Identity Association
    eks_client.create_pod_identity_association(
        clusterName=CLUSTER_NAME,
        namespace=ns,
        serviceAccount=f'openclaw-{tenant}',
        roleArn=TENANT_ROLE_ARN,
    )

    # 3. Trigger CodeBuild to run helm install
    cb.start_build(
        projectName=CODEBUILD_PROJECT,
        environmentVariablesOverride=[
            {'name': 'TENANT_NAME', 'value': tenant, 'type': 'PLAINTEXT'},
        ],
    )

    # 4. Notify admin
    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject='OpenClaw Account Ready',
        Message=f'Your AI assistant is being set up. It will be ready in about 2 minutes at: https://{tenant}.{DOMAIN}',
    )

    # 5. Welcome email to user
    ses.send_email(
        Source=os.environ.get('SES_FROM_EMAIL', f'noreply@{DOMAIN}'),
        Destination={'ToAddresses': [email]},
        Message={
            'Subject': {'Data': 'Your OpenClaw AI Assistant is Ready'},
            'Body': {'Text': {'Data': f'Welcome! Your personal AI assistant will be ready in about 2 minutes at: https://{tenant}.{DOMAIN}'}},
        },
    )

    return event
