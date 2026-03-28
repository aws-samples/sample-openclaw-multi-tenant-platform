#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
POOL_ID="${COGNITO_POOL_ID:-us-west-2_yRqDzKF0t}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

PRE_ARN=$(get_output PreSignupFnArn)
POST_ARN=$(get_output PostConfirmFnArn)

echo "==> Attaching Cognito triggers"
echo "  Pool: $POOL_ID"
echo "  PreSignUp: $PRE_ARN"
echo "  PostConfirmation: $POST_ARN"

aws cognito-idp update-user-pool \
  --user-pool-id "$POOL_ID" \
  --region "$REGION" \
  --lambda-config "PreSignUp=$PRE_ARN,PostConfirmation=$POST_ARN"

# Grant Cognito permission to invoke Lambdas
for ARN in "$PRE_ARN" "$POST_ARN"; do
  FN_NAME=$(echo "$ARN" | awk -F: '{print $NF}')
  aws lambda add-permission \
    --function-name "$FN_NAME" \
    --statement-id CognitoInvoke \
    --action lambda:InvokeFunction \
    --principal cognito-idp.amazonaws.com \
    --source-arn "arn:aws:cognito-idp:${REGION}:$(aws sts get-caller-identity --query Account --output text):userpool/${POOL_ID}" \
    --region "$REGION" 2>/dev/null || true
done

echo "=== Cognito triggers attached ==="
