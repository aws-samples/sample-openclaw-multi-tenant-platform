#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"
LOGO=""
[[ "${2:-}" == "--logo" ]] && LOGO="${3:-}"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

POOL_ID=$(get_output CognitoPoolId)
CLIENT_ID=$(get_output CognitoClientId)

echo "==> Applying Cognito branding"
echo "  Pool:   $POOL_ID"
echo "  Client: $CLIENT_ID"
echo "  Region: $REGION"

CSS=".background-customizable { background-color: #0a0a12; }
.banner-customizable { background-color: #0a0a12; }
.label-customizable { color: #ffffff; font-weight: 400; }
.textDescription-customizable { color: #cccccc; font-size: 14px; padding-top: 10px; padding-bottom: 10px; display: block; }
.inputField-customizable { color: #ffffff; background-color: #111119; border: 1px solid #6366F1; width: 100%; height: 40px; }
.inputField-customizable:focus { border: 1px solid #6366F1; }
.submitButton-customizable { background-color: #6366F1; color: #ffffff; font-size: 16px; font-weight: bold; width: 100%; height: 44px; margin: 20px 0 0 0; }
.submitButton-customizable:hover { background-color: #5558e6; color: #ffffff; }
.idpButton-customizable { background-color: #111119; color: #ffffff; height: 40px; }
.idpButton-customizable:hover { background-color: #1e1e2e; color: #ffffff; }
.socialButton-customizable { background-color: #111119; color: #ffffff; height: 40px; }
.logo-customizable { max-width: 400px; }
.legalText-customizable { color: #999999; }
.redirect-customizable { color: #6366F1; }"

CMD=(aws cognito-idp set-ui-customization
  --user-pool-id "$POOL_ID"
  --client-id "$CLIENT_ID"
  --css "$CSS"
  --region "$REGION")

[ -n "$LOGO" ] && [ -f "$LOGO" ] && CMD+=(--image-file "fileb://$LOGO")

"${CMD[@]}" > /dev/null
echo "✅ Cognito branding applied"
