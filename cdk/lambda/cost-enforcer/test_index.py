"""Tests for cost-enforcer Lambda."""
import json
import os
import sys
from unittest.mock import MagicMock, patch

import pytest

# Set required env vars before import
os.environ.setdefault('CLUSTER_NAME', 'test-cluster')
os.environ.setdefault('LOG_GROUP', '/aws/test')
os.environ.setdefault('SNS_TOPIC_ARN', 'arn:aws:sns:us-west-2:123456789012:test')

# Mock boto3 before importing the module
sys.modules['boto3'] = MagicMock()

from index import get_model_pricing, _DEFAULT_PRICING


def test_pricing_exact_match():
    """Known model ID returns correct pricing."""
    p = get_model_pricing('anthropic.claude-opus-4')
    assert p['input'] == 15.0
    assert p['output'] == 75.0


def test_pricing_partial_match():
    """Model ID containing a known key matches."""
    p = get_model_pricing('us.anthropic.claude-sonnet-4-v1')
    assert p['input'] == 3.0


def test_pricing_unknown_model_returns_default():
    """Unknown model falls back to default pricing."""
    p = get_model_pricing('some-unknown-model-xyz')
    assert p == _DEFAULT_PRICING['default']


def test_pricing_deepseek():
    """DeepSeek model matches by substring."""
    p = get_model_pricing('deepseek.v3.2')
    assert p['input'] == 0.14
    assert p['output'] == 0.28


def test_handler_no_data(monkeypatch):
    """Handler returns early when no usage data."""
    from index import handler
    monkeypatch.setattr('index.query_token_usage', lambda: {})
    result = handler({}, None)
    assert result['statusCode'] == 200
    assert result['body'] == 'no data'
