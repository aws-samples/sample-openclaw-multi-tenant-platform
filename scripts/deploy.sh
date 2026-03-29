#!/usr/bin/env bash
set -euo pipefail
echo '==> Step 1: CDK Deploy'
cd cdk && npm ci && npx cdk deploy OpenClawEksStack --require-approval broadening && cd ..
echo '==> Step 2: Setup Cognito'
bash scripts/setup-cognito.sh
echo '==> Step 3: Deploy Auth UI'
bash scripts/deploy-auth-ui.sh
echo '==> Step 4: Upload Helm Chart'
bash scripts/upload-helm-chart.sh
echo '==> Step 5: Deploy Gateway API'
kubectl apply -f helm/gateway.yaml
echo '==> Step 6: Install CRD + Operator'
kubectl apply -f operator/yaml/crd.yaml
kubectl apply -f operator/yaml/deployment.yaml
echo '==> Done! Visit https://'"$(cd cdk && node -e "console.log(require('./cdk.json').context.zoneName)")"''
