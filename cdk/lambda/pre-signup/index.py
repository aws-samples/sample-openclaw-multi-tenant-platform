import os
import boto3
import urllib.request
import json

sns = boto3.client('sns')
TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', '<YOUR_EMAIL_DOMAIN>').split(',')]
TURNSTILE_SECRET = os.environ.get('TURNSTILE_SECRET', '')

def verify_turnstile(token):
    data = json.dumps({'secret': TURNSTILE_SECRET, 'response': token}).encode()
    req = urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify',
                                data=data, headers={'Content-Type': 'application/json'})
    resp = json.loads(urllib.request.urlopen(req).read())
    if not resp.get('success'):
        raise Exception('CAPTCHA verification failed')

def handler(event, context):
    email = event['request']['userAttributes'].get('email', 'unknown')
    domain = email.split('@')[-1].lower() if '@' in email else ''

    if domain not in ALLOWED_DOMAINS:
        raise Exception(f'Email domain not allowed: {domain}')

    if TURNSTILE_SECRET:
        token = event['request'].get('clientMetadata', {}).get('turnstileToken', '')
        if not token:
            raise Exception('CAPTCHA token missing')
        verify_turnstile(token)

    event['response']['autoConfirmUser'] = False
    event['response']['autoVerifyEmail'] = True
    sns.publish(TopicArn=TOPIC_ARN, Subject='New User Signup', Message=f'New signup: {email}')
    return event
