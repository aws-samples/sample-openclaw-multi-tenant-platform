#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)
DOMAIN=$(get_output DomainName)
PRE_ARN=$(get_output PreSignupFnArn)
POST_ARN=$(get_output PostConfirmFnArn)

echo "==> Configuring Cognito User Pool"
echo "  Pool:   $POOL_ID"
echo "  Client: $CLIENT_ID"
echo "  Domain: $DOMAIN"

# 1. Enable email auto-verification
echo "  → Setting AutoVerifiedAttributes: email"
aws cognito-idp update-user-pool \
  --user-pool-id "$POOL_ID" \
  --auto-verified-attributes email \
  --admin-create-user-config '{"AllowAdminCreateUserOnly": false}' \
  --region "$REGION"

# 2. Update client: auth flows + callback URLs
echo "  → Updating client auth flows + callback URLs"
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

# 3. Attach Lambda triggers
echo "  → Attaching Lambda triggers"
aws cognito-idp update-user-pool \
  --user-pool-id "$POOL_ID" \
  --lambda-config "PreSignUp=$PRE_ARN,PostConfirmation=$POST_ARN" \
  --auto-verified-attributes email \
  --admin-create-user-config '{"AllowAdminCreateUserOnly": false}' \
  --region "$REGION"

# 4. Grant Cognito permission to invoke Lambdas
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

echo "✅ Cognito configured"
