#!/usr/bin/env bash
set -euo pipefail
# Called by CodeBuild to provision a new tenant.
# Env vars: TENANT_NAME, DOMAIN, CERTIFICATE_ARN, REGION, CHART_BUCKET

TENANT="$TENANT_NAME"
NS="openclaw-${TENANT}"
RELEASE="openclaw-${TENANT}"

echo "==> Provisioning tenant: ${TENANT}"

# Download chart + template
aws s3 cp "s3://${CHART_BUCKET}/openclaw-platform.tgz" /tmp/chart.tgz
aws s3 cp "s3://${CHART_BUCKET}/values-template.yaml" /tmp/values-template.yaml

# Substitute template
python3 << PYEOF
subs = {
    '{{TENANT}}': '${TENANT}',
    '{{DOMAIN}}': '${DOMAIN}',
    '{{CERTIFICATE_ARN}}': '${CERTIFICATE_ARN}',
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

echo "==> Done: ${TENANT}"
