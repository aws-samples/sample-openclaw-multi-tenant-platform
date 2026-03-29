#!/usr/bin/env bash
set -euo pipefail
# Called by CodeBuild to provision a new tenant.
# Env vars: TENANT_NAME, DOMAIN, CERTIFICATE_ARN, COGNITO_POOL_ID, ALB_CLIENT_ID, COGNITO_DOMAIN, REGION, CHART_BUCKET

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
content = content.replace('{{SKILLS_YAML}}', '  - weather\n  - gog')
with open('/tmp/values.yaml', 'w') as f:
    f.write(content)
PYEOF

echo "==> Helm upgrade --install"
helm upgrade --install "${RELEASE}" /tmp/chart.tgz \
  --namespace "${NS}" --create-namespace \
  -f /tmp/values.yaml

echo "==> Creating Gateway API resources"
cat << EOF | kubectl apply -f -
apiVersion: gateway.k8s.aws/v1beta1
kind: TargetGroupConfiguration
metadata:
  name: openclaw-${TENANT}-tg
  namespace: ${NS}
spec:
  targetReference:
    name: openclaw-${TENANT}
  defaultConfiguration:
    targetType: ip
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openclaw-${TENANT}
  namespace: ${NS}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: openclaw-gateway
      namespace: openclaw-system
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /t/${TENANT}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: openclaw-${TENANT}
          port: 18789
EOF

echo "==> Done: ${TENANT}"
