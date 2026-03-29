import os
import boto3
import urllib.request
import json

sns = boto3.client('sns')
TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', 'example.com').split(',')]
TURNSTILE_SECRET = os.environ.get('TURNSTILE_SECRET', '')

def verify_turnstile(token):
    if not token:
        raise Exception('CAPTCHA verification required')
    data = json.dumps({'secret': TURNSTILE_SECRET, 'response': token}).encode()
    req = urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify',
                                 data=data, headers={'Content-Type': 'application/json'})
    resp = json.loads(urllib.request.urlopen(req).read())
    if not resp.get('success'):
        raise Exception('CAPTCHA verification failed')

def handler(event, context):
    email = event['request']['userAttributes'].get('email', 'unknown')
    domain = email.split('@')[-1].lower() if '@' in email else ''

    # Gate: only allowed email domains
    if domain not in ALLOWED_DOMAINS:
        raise Exception(f'Email domain not allowed: {domain}')

    # Gate: CAPTCHA (if configured)
    if TURNSTILE_SECRET:
        token = event['request'].get('clientMetadata', {}).get('turnstileToken', '')
        verify_turnstile(token)

    # Auto-confirm: email domain is the trust gate, no admin approval needed
    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True

    # Notify admin (informational, not approval)
    sns.publish(TopicArn=TOPIC_ARN, Subject='New User Registered', Message=f'New user: {email}')
    return event
