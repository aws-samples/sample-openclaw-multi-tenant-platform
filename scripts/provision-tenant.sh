#!/usr/bin/env bash
set -euo pipefail
# Called by CodeBuild to provision a new tenant.
# Env vars: TENANT_NAME, DOMAIN, CERTIFICATE_ARN, COGNITO_POOL_ID, COGNITO_CLIENT_ID, COGNITO_DOMAIN, REGION, CHART_BUCKET

TENANT="$TENANT_NAME"
NS="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"

echo "==> Provisioning tenant: ${TENANT}"

# Download chart + template
aws s3 cp "s3://${CHART_BUCKET}/openclaw-platform.tgz" /tmp/chart.tgz
aws s3 cp "s3://${CHART_BUCKET}/values-template.yaml" /tmp/values-template.yaml

# Get account ID
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
POOL_ARN="arn:aws:cognito-idp:${REGION}:${ACCOUNT}:userpool/${COGNITO_POOL_ID}"

# Substitute template
python3 << PYEOF
subs = {
    '{{TENANT}}': '${TENANT}',
    '{{DOMAIN}}': '${DOMAIN}',
    '{{CERTIFICATE_ARN}}': '${CERTIFICATE_ARN}',
    '{{COGNITO_POOL_ARN}}': '${POOL_ARN}',
    '{{COGNITO_CLIENT_ID}}': '${ALB_CLIENT_ID}',
    '{{COGNITO_DOMAIN}}': '${COGNITO_DOMAIN}',
    '{{TENANT_DISPLAY_NAME}}': 'OpenClaw',
    '{{TENANT_EMOJI}}': '',
    '{{BUDGET_USD}}': '100',
}
with open('/tmp/values-template.yaml') as f:
    content = f.read()
for k, v in subs.items():
    content = content.replace(k, v)
# Handle SKILLS_YAML (multi-line)
content = content.replace('{{SKILLS_YAML}}', '  - weather\n  - gog')
with open('/tmp/values.yaml', 'w') as f:
    f.write(content)
PYEOF

echo "==> Generated values.yaml"
cat /tmp/values.yaml

# Add Cognito callback URL
echo "==> Adding Cognito callback URL"
NEW_CB="https://${TENANT}.${DOMAIN}/oauth2/idpresponse"
python3 << CBEOF
import json, subprocess
result = subprocess.run(
    ['aws', 'cognito-idp', 'describe-user-pool-client',
     '--user-pool-id', '${COGNITO_POOL_ID}', '--client-id', '${ALB_CLIENT_ID}',
     '--region', '${REGION}', '--query', 'UserPoolClient.CallbackURLs', '--output', 'json'],
    capture_output=True, text=True)
urls = json.loads(result.stdout)
new_cb = '${NEW_CB}'
if new_cb not in urls:
    urls.append(new_cb)
    subprocess.run(
        ['aws', 'cognito-idp', 'update-user-pool-client',
         '--user-pool-id', '${COGNITO_POOL_ID}', '--client-id', '${ALB_CLIENT_ID}',
         '--callback-urls'] + urls + [
         '--explicit-auth-flows', 'ALLOW_USER_PASSWORD_AUTH', 'ALLOW_REFRESH_TOKEN_AUTH', 'ALLOW_USER_SRP_AUTH',
         '--allowed-o-auth-flows', 'code', '--allowed-o-auth-scopes', 'openid', 'email', 'profile',
         '--allowed-o-auth-flows-user-pool-client', '--supported-identity-providers', 'COGNITO',
         '--region', '${REGION}'], capture_output=True)
    print(f'  Added: {new_cb}')
else:
    print(f'  Already exists: {new_cb}')
CBEOF

echo "==> Helm install"
helm upgrade --install "${RELEASE}" /tmp/chart.tgz \
  --namespace "${NS}" --create-namespace \
  -f /tmp/values.yaml \
  --wait --timeout 180s

echo "==> Done: ${TENANT}"
