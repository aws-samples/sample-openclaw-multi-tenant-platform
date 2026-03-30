import os
import json
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', 'example.com').split(',')]
TURNSTILE_SECRET = os.environ.get('TURNSTILE_SECRET', '')
USER_POOL_ID = os.environ.get('USER_POOL_ID', '')
RATE_LIMIT = int(os.environ.get('SIGNUP_RATE_LIMIT', '5'))

cognito_client = boto3.client('cognito-idp') if USER_POOL_ID else None


def _count_recent_signups(domain):
    """Count users with the same email domain created in the last hour.

    Performance note: Cognito ListUsers does not support domain-based filtering
    (only username, email, phone_number, name prefix). This scans all users and
    filters client-side, which is acceptable for small user pools typical of
    company-internal deployments behind an email domain allowlist.

    For production deployments with 1000+ users, consider replacing this with a
    DynamoDB atomic counter keyed on (domain, hour) to avoid O(n) scans.
    """
    if not cognito_client or not USER_POOL_ID:
        return 0
    cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
    count = 0
    params = {
        'UserPoolId': USER_POOL_ID,
        'Limit': 60,
    }
    while True:
        resp = cognito_client.list_users(**params)
        for user in resp.get('Users', []):
            create_date = user.get('UserCreateDate')
            if create_date and create_date < cutoff:
                continue
            for attr in user.get('Attributes', []):
                if attr['Name'] == 'email' and attr['Value'].lower().endswith(f'@{domain}'):
                    count += 1
        token = resp.get('PaginationToken')
        if not token:
            break
        params['PaginationToken'] = token
    return count


def handler(event, context):
    email = event['request']['userAttributes'].get('email', '')
    domain = email.split('@')[-1].lower() if '@' in email else ''

    if domain not in ALLOWED_DOMAINS:
        raise Exception('Registration is restricted to company email addresses.')

    # Rate limit: max RATE_LIMIT signups per domain per hour
    if _count_recent_signups(domain) >= RATE_LIMIT:
        raise Exception(f'Too many signups from {domain}. Please try again later.')

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

    return event
