#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
STACK="OpenClawEksStack"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Usage: $0 [--region REGION]"; exit 1 ;;
  esac
done

POOL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoPoolId'].OutputValue" --output text)

if [ -z "$POOL_ID" ] || [ "$POOL_ID" = "None" ]; then
  echo "❌ CognitoPoolId not found in $STACK outputs"; exit 1
fi

echo "📋 Tenants (User Pool: $POOL_ID)"
echo ""
printf "%-30s %-14s %-20s\n" "EMAIL" "STATUS" "CREATED"
printf "%-30s %-14s %-20s\n" "------------------------------" "--------------" "--------------------"

aws cognito-idp list-users --user-pool-id "$POOL_ID" --region "$REGION" \
  --query 'Users[].{u:Username,s:UserStatus,c:UserCreateDate,a:Attributes}' --output json \
| python3 -c "
import json,sys
users=json.load(sys.stdin)
for u in sorted(users, key=lambda x: x['c']):
    email=next((a['Value'] for a in u['a'] if a['Name']=='email'), u['u'])
    created=u['c'][:19].replace('T',' ')
    print(f\"{email:<30} {u['s']:<14} {created}\")
"

# Per-tenant cost from CloudWatch (current month)
MONTH=$(date +%Y-%m)
START="${MONTH}-01T00:00:00Z"
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NS="OpenClaw/Usage"

echo ""
echo "💰 Current month token usage ($MONTH)"
echo ""

METRICS=$(aws cloudwatch list-metrics --namespace "$NS" --region "$REGION" \
  --query 'Metrics[?MetricName==`InputTokens`].Dimensions[0].Value' --output json 2>/dev/null || echo '[]')

if [ "$METRICS" = "[]" ] || [ "$METRICS" = "" ]; then
  echo "  (No usage metrics found in $NS namespace)"
  exit 0
fi

printf "%-15s %15s %15s %12s\n" "TENANT" "INPUT_TOKENS" "OUTPUT_TOKENS" "EST_COST"
printf "%-15s %15s %15s %12s\n" "---------------" "---------------" "---------------" "------------"

echo "$METRICS" | python3 -c "
import json,sys,subprocess
tenants=json.load(sys.stdin)
for t in sorted(set(tenants)):
    def get_sum(metric):
        r=subprocess.run(['aws','cloudwatch','get-metric-statistics','--namespace','$NS',
          '--metric-name',metric,'--dimensions','Name=Tenant,Value='+t,
          '--start-time','$START','--end-time','$END','--period','2592000',
          '--statistics','Sum','--region','$REGION','--output','json'],
          capture_output=True,text=True)
        dp=json.loads(r.stdout).get('Datapoints',[])
        return int(dp[0]['Sum']) if dp else 0
    inp=get_sum('InputTokens')
    out=get_sum('OutputTokens')
    cost=inp*3.0/1_000_000+out*15.0/1_000_000
    print(f'{t:<15} {inp:>15,} {out:>15,} \${cost:>11,.2f}')
"
