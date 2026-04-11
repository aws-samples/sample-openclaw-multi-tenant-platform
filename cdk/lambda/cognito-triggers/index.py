"""Custom resource: attach Lambda triggers to Cognito UserPool via read-modify-write.

Uses DescribeUserPool + UpdateUserPool to safely merge LambdaConfig without
overwriting any other UserPool settings. This avoids the full-replacement
problem of calling UpdateUserPool directly with AwsCustomResource.

See: https://github.com/aws/aws-cdk/issues/7016
"""
import json
import logging
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cognito = boto3.client('cognito-idp')


def handler(event, context):
    try:
        result = _handle(event, context)
        _send(event, context, 'SUCCESS', result)
    except Exception as e:
        logger.exception('Failed')
        _send(event, context, 'FAILED', {}, str(e))


def _handle(event, context):
    request_type = event['RequestType']
    props = event['ResourceProperties']
    pool_id = props['UserPoolId']

    if request_type in ('Create', 'Update'):
        # Read current config
        current = cognito.describe_user_pool(UserPoolId=pool_id)['UserPool']

        # Build update params from current state (preserves all settings)
        update_params = _extract_updatable(current)
        update_params['UserPoolId'] = pool_id

        # Merge only LambdaConfig
        update_params['LambdaConfig'] = {
            'PreSignUp': props['PreSignUpArn'],
            'PostConfirmation': props['PostConfirmationArn'],
        }

        cognito.update_user_pool(**update_params)
        logger.info('Triggers attached to %s', pool_id)
        return {'UserPoolId': pool_id}

    elif request_type == 'Delete':
        # Read current config, remove our triggers
        current = cognito.describe_user_pool(UserPoolId=pool_id)['UserPool']
        update_params = _extract_updatable(current)
        update_params['UserPoolId'] = pool_id
        update_params['LambdaConfig'] = {}
        cognito.update_user_pool(**update_params)
        logger.info('Triggers removed from %s', pool_id)
        return {}


def _extract_updatable(pool):
    """Extract fields from DescribeUserPool that are valid for UpdateUserPool."""
    params = {}

    # Direct copy fields
    for key in [
        'Policies', 'DeletionProtection', 'AutoVerifiedAttributes',
        'SmsVerificationMessage', 'EmailVerificationMessage', 'EmailVerificationSubject',
        'VerificationMessageTemplate', 'SmsAuthenticationMessage',
        'UserAttributeUpdateSettings', 'MfaConfiguration', 'DeviceConfiguration',
        'EmailConfiguration', 'SmsConfiguration', 'UserPoolTags',
        'AdminCreateUserConfig', 'UserPoolAddOns', 'AccountRecoverySetting',
    ]:
        if key in pool and pool[key] is not None:
            params[key] = pool[key]

    # LambdaConfig — will be overwritten by caller
    if 'LambdaConfig' in pool:
        params['LambdaConfig'] = pool['LambdaConfig']

    return params


def _send(event, context, status, data, reason='OK'):
    body = json.dumps({
        'Status': status,
        'Reason': reason,
        'PhysicalResourceId': event.get('PhysicalResourceId', 'cognito-triggers'),
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': False,
        'Data': data,
    })
    req = urllib.request.Request(
        event['ResponseURL'],
        data=body.encode(),
        headers={'Content-Type': ''},
        method='PUT',
    )
    urllib.request.urlopen(req)
