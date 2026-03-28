#!/usr/bin/env bash
set -euo pipefail
REGION="${1:-us-west-2}"
PROFILE="${2:-bedrock-only}"
STACK="OpenClawEksStack"

echo "[$(date +%H:%M:%S)] Waiting for stack rollback to complete..."
while true; do
  STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK" --profile "$PROFILE" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
  case "$STATUS" in
    ROLLBACK_COMPLETE)
      echo "[$(date +%H:%M:%S)] Rollback complete. Deleting failed stack..."
      aws cloudformation delete-stack --stack-name "$STACK" --profile "$PROFILE" --region "$REGION"
      aws cloudformation wait stack-delete-complete --stack-name "$STACK" --profile "$PROFILE" --region "$REGION"
      echo "[$(date +%H:%M:%S)] Stack deleted."
      break
      ;;
    DOES_NOT_EXIST|DELETE_COMPLETE)
      echo "[$(date +%H:%M:%S)] Stack clean. Ready to deploy."
      break
      ;;
    *_IN_PROGRESS)
      echo "[$(date +%H:%M:%S)] Status: $STATUS — waiting 30s..."
      sleep 30
      ;;
    *)
      echo "[$(date +%H:%M:%S)] Unexpected status: $STATUS"
      exit 1
      ;;
  esac
done

echo "[$(date +%H:%M:%S)] Starting cdk deploy..."
cd ~/projects/openclaw-platform/cdk
npx cdk deploy --profile "$PROFILE" --region "$REGION" --require-approval never --outputs-file ../cdk-outputs.json 2>&1 | tee ../deploy.log
echo "[$(date +%H:%M:%S)] Deploy finished with exit code: $?"
