#!/usr/bin/env bash
set -euo pipefail

REGION="us-west-2"
LOGO=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --logo)   LOGO="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *)        echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

COGNITO_POOL_ID="${COGNITO_POOL_ID:-us-west-2_yRqDzKF0t}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-103uif8rdrp29ak4eki7lc09ru}"

CSS=$(cat <<'EOF'
.background-customizable { background-color: #1a1a2e; }
.banner-customizable { background-color: #1a1a2e; }
.label-customizable { color: #ffffff; font-weight: 400; }
.textDescription-customizable { color: #cccccc; font-size: 14px; padding-top: 10px; padding-bottom: 10px; display: block; }
.inputField-customizable { color: #ffffff; background-color: #16213e; border: 1px solid #e94560; width: 100%; height: 40px; }
.inputField-customizable:focus { border: 1px solid #e94560; }
.submitButton-customizable { background-color: #e94560; color: #ffffff; font-size: 16px; font-weight: bold; width: 100%; height: 44px; margin: 20px 0 0 0; }
.submitButton-customizable:hover { background-color: #c73652; color: #ffffff; }
.idpButton-customizable { background-color: #16213e; color: #ffffff; height: 40px; }
.idpButton-customizable:hover { background-color: #0f3460; color: #ffffff; }
.socialButton-customizable { background-color: #16213e; color: #ffffff; height: 40px; }
.logo-customizable { max-width: 400px; }
.legalText-customizable { color: #999999; }
.redirect-customizable { color: #e94560; }
EOF
)

CMD=(
  aws cognito-idp set-ui-customization
  --user-pool-id "$COGNITO_POOL_ID"
  --client-id "$COGNITO_CLIENT_ID"
  --css "$CSS"
  --region "$REGION"
)

if [[ -n "$LOGO" ]]; then
  [[ -f "$LOGO" ]] || { echo "Logo file not found: $LOGO" >&2; exit 1; }
  CMD+=(--image-file "fileb://$LOGO")
fi

echo "Setting Cognito Hosted UI branding..."
echo "  Pool:   $COGNITO_POOL_ID"
echo "  Client: $COGNITO_CLIENT_ID"
echo "  Region: $REGION"
[[ -n "$LOGO" ]] && echo "  Logo:   $LOGO"

"${CMD[@]}"
echo "Done."
