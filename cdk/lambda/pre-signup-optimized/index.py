import os
import json
from datetime import datetime, timedelta, timezone

import boto3

ALLOWED_DOMAINS = [d.strip() for d in os.environ.get('ALLOWED_DOMAINS', 'example.com').split(',')]
USER_POOL_ID = os.environ.get('USER_POOL_ID', '')
RATE_LIMIT = int(os.environ.get('SIGNUP_RATE_LIMIT', '5'))
COUNTER_TABLE = os.environ.get('COUNTER_TABLE', '')

cognito_client = boto3.client('cognito-idp') if USER_POOL_ID else None
dynamodb = boto3.resource('dynamodb') if COUNTER_TABLE else None

def _count_recent_signups_optimized(domain):
    """Count recent signups using DynamoDB atomic counter (production-ready).

    Uses DynamoDB table with partition key: domain + hour bucket.
    This scales to millions of users without O(n) Cognito scans.

    Table schema:
    - PK: domain_hour (e.g., "example.com#2026-04-11-15")
    - counter: number (atomic counter)
    - ttl: number (TTL for automatic cleanup after 24h)
    """
    if not dynamodb or not COUNTER_TABLE:
        # Fallback to original O(n) method for backward compatibility
        return _count_recent_signups_fallback(domain)

    table = dynamodb.Table(COUNTER_TABLE)
    current_hour = datetime.now(timezone.utc).strftime('%Y-%m-%d-%H')
    pk = f"{domain}#{current_hour}"

    try:
        response = table.get_item(Key={'domain_hour': pk})
        return response.get('Item', {}).get('counter', 0)
    except Exception:
        # Fallback on DynamoDB errors
        return _count_recent_signups_fallback(domain)

def _count_recent_signups_fallback(domain):
    """Original O(n) method - acceptable for small deployments."""
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
        if 'PaginationToken' not in resp:
            break
        params['PaginationToken'] = resp['PaginationToken']
    return count

def _increment_signup_counter(domain):
    """Increment atomic counter in DynamoDB."""
    if not dynamodb or not COUNTER_TABLE:
        return  # Skip if DynamoDB not configured

    table = dynamodb.Table(COUNTER_TABLE)
    current_hour = datetime.now(timezone.utc).strftime('%Y-%m-%d-%H')
    pk = f"{domain}#{current_hour}"
    ttl = int((datetime.now(timezone.utc) + timedelta(hours=25)).timestamp())  # 25h TTL

    try:
        table.update_item(
            Key={'domain_hour': pk},
            UpdateExpression='ADD counter :inc SET ttl = :ttl',
            ExpressionAttributeValues={':inc': 1, ':ttl': ttl}
        )
    except Exception:
        pass  # Ignore DynamoDB errors (rate limiting is best-effort)

def lambda_handler(event, context):
    """PreSignUp trigger: email domain gate + rate limiting."""
    email = event['request']['userAttributes']['email'].lower()
    domain = email.split('@')[-1] if '@' in email else ''

    # Domain allowlist check
    if domain not in ALLOWED_DOMAINS:
        raise Exception(f"Email domain {domain} not allowed. Allowed domains: {', '.join(ALLOWED_DOMAINS)}")

    # Rate limiting check
    if RATE_LIMIT > 0:
        current_count = _count_recent_signups_optimized(domain)
        if current_count >= RATE_LIMIT:
            raise Exception(f"Rate limit exceeded: {current_count}/{RATE_LIMIT} signups from {domain} in the last hour")

    # Increment counter for successful signups (only if using DynamoDB)
    _increment_signup_counter(domain)

    return event