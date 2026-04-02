"""Unit tests for pre-signup Lambda.

Tests the pure logic (domain validation, rate limiting) without AWS calls.
Run: python3 -m pytest cdk/lambda/pre-signup/test_index.py -v
"""
import os
import sys
from unittest.mock import patch

# Set required env vars before import
os.environ.setdefault('ALLOWED_DOMAINS', 'example.com,test.org')
os.environ.setdefault('USER_POOL_ID', '')
os.environ.setdefault('SIGNUP_RATE_LIMIT', '5')

sys.path.insert(0, os.path.dirname(__file__))
import index


def _event(email):
    return {'request': {'userAttributes': {'email': email}}}


def test_allowed_domain_passes():
    result = index.handler(_event('user@example.com'), None)
    assert result == _event('user@example.com')


def test_disallowed_domain_raises():
    import pytest
    with pytest.raises(Exception, match='restricted'):
        index.handler(_event('user@evil.com'), None)


def test_multiple_allowed_domains():
    result = index.handler(_event('user@test.org'), None)
    assert result['request']['userAttributes']['email'] == 'user@test.org'


def test_rate_limit_blocks():
    import pytest
    with patch.object(index, '_count_recent_signups', return_value=10):
        with pytest.raises(Exception, match='(?i)too many'):
            index.handler(_event('user@example.com'), None)


def test_rate_limit_allows_under_threshold():
    with patch.object(index, '_count_recent_signups', return_value=2):
        result = index.handler(_event('user@example.com'), None)
        assert result is not None
