import json
import os
import time
from datetime import datetime, timezone

import boto3

_DEFAULT_PRICING = {
    'anthropic.claude-opus-4': {'input': 15.0, 'output': 75.0},
    'anthropic.claude-sonnet-4': {'input': 3.0, 'output': 15.0},
    'deepseek': {'input': 0.14, 'output': 0.28},
    'default': {'input': 3.0, 'output': 15.0},
}
PRICING = json.loads(os.environ['PRICING_JSON']) if os.environ.get('PRICING_JSON') else _DEFAULT_PRICING

CLUSTER_NAME = os.environ['CLUSTER_NAME']
LOG_GROUP = os.environ['LOG_GROUP']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
REGION = os.environ.get('REGION', os.environ.get('AWS_REGION', 'us-west-2'))

logs = boto3.client('logs', region_name=REGION)
sm = boto3.client('secretsmanager', region_name=REGION)
sns = boto3.client('sns', region_name=REGION)


def get_model_pricing(model_id: str) -> dict:
    for key in PRICING:
        if key in model_id:
            return PRICING[key]
    return PRICING['default']


def query_token_usage() -> dict:
    """Query CloudWatch Logs Insights for per-namespace Bedrock token usage this month."""
    now = datetime.now(timezone.utc)
    start = int(datetime(now.year, now.month, 1, tzinfo=timezone.utc).timestamp())
    end = int(now.timestamp())

    query = """
    fields kubernetes.namespace_name as ns, @message
    | filter @message like /inputTokens|input_tokens/
    | parse @message /(?i)model[_"]?:?\s*"?(?<model>[a-z0-9._-]+)"?/
    | parse @message /(?i)input.?[Tt]okens[_"]?:?\s*(?<inp>\d+)/
    | parse @message /(?i)output.?[Tt]okens[_"]?:?\s*(?<outp>\d+)/
    | stats sum(inp) as total_input, sum(outp) as total_output by ns, model
    """

    resp = logs.start_query(
        logGroupName=LOG_GROUP,
        startTime=start,
        endTime=end,
        queryString=query,
    )
    query_id = resp['queryId']

    for _ in range(30):
        time.sleep(2)  # nosemgrep: arbitrary-sleep -- polling CloudWatch Logs Insights query completion
        result = logs.get_query_results(queryId=query_id)
        if result['status'] == 'Complete':
            break
    else:
        print('WARNING: query did not complete in time')
        return {}

    # Aggregate cost per namespace
    ns_costs: dict[str, float] = {}
    for row in result.get('results', []):
        fields = {f['field']: f['value'] for f in row}
        ns = fields.get('ns', '')
        model = fields.get('model', '')
        inp = int(fields.get('total_input', 0))
        outp = int(fields.get('total_output', 0))
        p = get_model_pricing(model)
        cost = (inp * p['input'] + outp * p['output']) / 1_000_000
        ns_costs[ns] = ns_costs.get(ns, 0) + cost

    return ns_costs


def get_tenant_budget(tenant_name: str) -> float:
    """Read budget-usd tag from tenant's Secrets Manager secret."""
    secret_id = f'openclaw/{tenant_name}/gateway-token'
    try:
        resp = sm.describe_secret(SecretId=secret_id)
        for tag in resp.get('Tags', []):
            if tag['Key'] == 'budget-usd':
                return float(tag['Value'])
    except Exception as e:
        print(f'Cannot read budget for {tenant_name}: {e}')
    return 100.0


def handler(event, context):
    print('Cost enforcer triggered')
    ns_costs = query_token_usage()
    if not ns_costs:
        print('No usage data found')
        return {'statusCode': 200, 'body': 'no data'}

    alerts = []
    for ns, cost in ns_costs.items():
        if not ns.startswith('openclaw-'):
            continue
        tenant = ns.removeprefix('openclaw-')
        budget = get_tenant_budget(tenant)
        pct = (cost / budget * 100) if budget > 0 else 0
        print(f'{ns}: ${cost:.2f} / ${budget:.2f} ({pct:.0f}%)')

        if cost >= budget:
            alerts.append(f'🚨 OVER BUDGET: {ns} — ${cost:.2f} / ${budget:.2f}')
        elif pct >= 80:
            alerts.append(f'⚠️ 80% budget: {ns} — ${cost:.2f} / ${budget:.2f}')

    if alerts:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f'OpenClaw Cost Alert — {datetime.now(timezone.utc):%Y-%m-%d}',
            Message='\n'.join(alerts),
        )
        print(f'Sent {len(alerts)} alert(s)')

    return {'statusCode': 200, 'body': json.dumps(ns_costs, default=str)}
