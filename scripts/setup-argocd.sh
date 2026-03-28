#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
CLUSTER="openclaw-cluster"
CAPABILITY_NAME="openclaw-argocd"

echo "==> ArgoCD (EKS Capability)"

# Check if capability exists
STATUS=$(aws eks describe-capability --cluster-name "$CLUSTER" --capability-name "$CAPABILITY_NAME" --type ARGOCD --region "$REGION" --query 'capability.status' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$STATUS" = "NOT_FOUND" ]; then
  echo "  ArgoCD capability not found. Create it with:"
  echo ""
  echo "  aws eks create-capability \\"
  echo "    --capability-name $CAPABILITY_NAME \\"
  echo "    --cluster-name $CLUSTER \\"
  echo "    --type ARGOCD \\"
  echo "    --role-arn <EKSArgoCDCapabilityRole ARN> \\"
  echo "    --delete-propagation-policy RETAIN \\"
  echo "    --configuration '{\"argoCd\":{\"namespace\":\"argocd\",\"awsIdc\":{\"idcInstanceArn\":\"<IDC_ARN>\",\"idcRegion\":\"<IDC_REGION>\"},\"rbacRoleMappings\":[{\"role\":\"ADMIN\",\"identities\":[{\"id\":\"<SSO_USER_ID>\",\"type\":\"SSO_USER\"}]}]}}' \\"
  echo "    --region $REGION"
  echo ""
  echo "  Prerequisites: AWS Identity Center + IAM Capability Role"
  echo "  See: https://docs.aws.amazon.com/eks/latest/userguide/create-argocd-capability.html"
  exit 1
fi

echo "  Status: $STATUS"

if [ "$STATUS" = "ACTIVE" ]; then
  # Get ArgoCD UI URL
  UI_URL=$(aws eks describe-capability --cluster-name "$CLUSTER" --capability-name "$CAPABILITY_NAME" --type ARGOCD --region "$REGION" --query 'capability.configuration.argoCd.argoUiUrl' --output text 2>/dev/null || echo "")
  echo "  UI: ${UI_URL:-'(not yet available)'}"
  echo ""
  echo "=== ArgoCD is ACTIVE ==="
  echo "  Access the UI via AWS Identity Center SSO"
  echo "  Apply ApplicationSets: ./scripts/setup-argocd-apps.sh"
else
  echo "  Waiting for capability to become ACTIVE..."
  echo "  Check status: aws eks describe-capability --cluster-name $CLUSTER --capability-name $CAPABILITY_NAME --type ARGOCD --region $REGION"
fi
