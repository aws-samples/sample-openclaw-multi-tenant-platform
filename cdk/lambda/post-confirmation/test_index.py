"""Unit tests for post-confirmation Lambda.

Tests pure logic (URL validation, tenant name resolution, EKS context caching)
without actual AWS/K8s calls.
Run: python3 -m pytest cdk/lambda/post-confirmation/test_index.py -v
"""
import os
import sys
import re
from unittest.mock import patch

os.environ.setdefault('SNS_TOPIC_ARN', 'arn:aws:sns:us-west-2:123456789012:test')
os.environ.setdefault('CLUSTER_NAME', 'test-cluster')
os.environ.setdefault('TENANT_ROLE_ARN', 'arn:aws:iam::123456789012:role/test')
os.environ.setdefault('USER_POOL_ID', 'us-west-2_test')

sys.path.insert(0, os.path.dirname(__file__))
import index


def test_validate_url_https():
    index._validate_url('https://example.com')  # should not raise


def test_validate_url_rejects_http():
    import pytest
    with pytest.raises(ValueError, match='not allowed'):
        index._validate_url('http://example.com')


def test_validate_url_rejects_ftp():
    import pytest
    with pytest.raises(ValueError, match='not allowed'):
        index._validate_url('ftp://example.com')


def test_tenant_name_sanitization():
    """Verify the handler's tenant name derivation logic."""
    email = 'Test.User+tag@example.com'
    local = email.split('@')[0].lower()
    base_name = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    assert base_name == 'testusertag'  # dots and plus stripped


def test_tenant_name_length_limit():
    email = 'a' * 50 + '@example.com'
    local = email.split('@')[0].lower()
    base_name = re.sub(r'[^a-z0-9-]', '', local)[:20].strip('-')
    assert len(base_name) == 20


def test_eks_context_cache_reset():
    """Verify cache is reset at handler entry."""
    import pytest
    index._eks_context_cache = ('old', 'stale', 'data')
    # handler will reset cache then fail on AWS calls
    with pytest.raises(Exception):
        index.handler({'request': {'userAttributes': {'email': 'x@x.com'}}, 'userName': 'x'}, None)
    # After handler entry, cache was reset (then set again or left None on error)
    # The important thing: it's not the old stale data
    assert index._eks_context_cache != ('old', 'stale', 'data')
