import os
import json
import urllib.request

ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', 'example.com').split(',')]
TURNSTILE_SECRET = os.environ.get('TURNSTILE_SECRET', '')

def handler(event, context):
    email = event['request']['userAttributes'].get('email', '')
    domain = email.split('@')[-1].lower() if '@' in email else ''

    if domain not in ALLOWED_DOMAINS:
        raise Exception('Registration is restricted to company email addresses.')

    if TURNSTILE_SECRET:
        token = event['request'].get('clientMetadata', {}).get('turnstileToken', '')
        if not token:
            raise Exception('CAPTCHA verification required.')
        data = json.dumps({'secret': TURNSTILE_SECRET, 'response': token}).encode()
        req = urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify',
                                     data=data, headers={'Content-Type': 'application/json'})
        resp = json.loads(urllib.request.urlopen(req).read())
        if not resp.get('success'):
            raise Exception('CAPTCHA verification failed.')

    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True

    return event
