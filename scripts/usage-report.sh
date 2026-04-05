#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
MONTH=$(date -d "$(date +%Y-%m-01) -1 day" +%Y-%m 2>/dev/null || date -v-1m +%Y-%m)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --month) MONTH="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "Usage: $0 [--month YYYY-MM] [--region REGION]"; exit 1 ;;
  esac
done

LOG_GROUP="/aws/containerinsights/openclaw-cluster/application"
START=$(date -d "${MONTH}-01" +%s 2>/dev/null || date -jf "%Y-%m-%d" "${MONTH}-01" +%s)
END=$(date -d "${MONTH}-01 +1 month" +%s 2>/dev/null || date -v+1m -jf "%Y-%m-%d" "${MONTH}-01" +%s)

QUERY='stats sum(input_tokens) as input_tok, sum(output_tokens) as output_tok by kubernetes.namespace_name as ns'

echo "🔍 Querying $MONTH usage (${LOG_GROUP})..."
QID=$(aws logs start-query --region "$REGION" \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START" --end-time "$END" \
  --query-string "$QUERY" \
  --output text --query 'queryId')

# Poll for results
STATUS="Running"
while [[ "$STATUS" == "Running" || "$STATUS" == "Scheduled" ]]; do
  sleep 2
  RESULT=$(aws logs get-query-results --region "$REGION" --query-id "$QID")
  STATUS=$(echo "$RESULT" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)
done

if [[ "$STATUS" != "Complete" ]]; then
  echo "❌ Query failed: $STATUS"
  exit 1
fi

# Cost: Sonnet input $3/1M, output $15/1M
INPUT_RATE="3.0"
OUTPUT_RATE="15.0"

printf "\n%-12s %15s %15s %12s\n" "TENANT" "INPUT_TOKENS" "OUTPUT_TOKENS" "EST_COST"
printf "%-12s %15s %15s %12s\n" "------------" "---------------" "---------------" "------------"

echo "$RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for row in data.get('results', []):
    r = {f['field']: f['value'] for f in row}
    ns = r.get('ns', '')
    if not ns.startswith('openclaw-'): continue
    tenant = ns.replace('openclaw-', '')
    inp = int(float(r.get('input_tok', 0)))
    out = int(float(r.get('output_tok', 0)))
    cost = inp * $INPUT_RATE / 1_000_000 + out * $OUTPUT_RATE / 1_000_000
    print(f'{tenant:<12} {inp:>15,} {out:>15,} \${cost:>11,.2f}')
"

echo ""
echo "💰 Cost formula: input \$${INPUT_RATE}/1M + output \$${OUTPUT_RATE}/1M (Sonnet)"
