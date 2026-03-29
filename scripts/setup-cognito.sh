#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null; }

POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)
DOMAIN=$(get_output DomainName)
PRE_ARN=$(get_output PreSignupFnArn)
POST_ARN=$(get_output PostConfirmFnArn)

echo "==> Configuring Cognito User Pool"
echo "  Pool:   $POOL_ID"
echo "  Client: $CLIENT_ID"
echo "  Domain: $DOMAIN"

# 1. User pool: ALL settings in ONE call (update-user-pool replaces entire config)
echo "  → Updating user pool (self-signup + email verify + Lambda triggers)"
aws cognito-idp update-user-pool \
  --user-pool-id "$POOL_ID" \
  --auto-verified-attributes email \
  --admin-create-user-config '{"AllowAdminCreateUserOnly": false}' \
  --lambda-config "PreSignUp=$PRE_ARN,PostConfirmation=$POST_ARN" \
  --region "$REGION"

# 2. Client: auth flows + callback URLs
echo "  → Updating client"
aws cognito-idp update-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
  --callback-urls "https://${DOMAIN}/oauth2/idpresponse" \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO \
  --region "$REGION" > /dev/null

# 3. Lambda invoke permissions
echo "  → Setting Lambda permissions"
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

# 4. Verify
echo ""
echo "=== Cognito Configured ==="
LAMBDA_CHECK=$(aws cognito-idp describe-user-pool --user-pool-id "$POOL_ID" --region "$REGION" --query 'UserPool.LambdaConfig')
echo "  Lambda triggers: $LAMBDA_CHECK"
echo "=========================="
