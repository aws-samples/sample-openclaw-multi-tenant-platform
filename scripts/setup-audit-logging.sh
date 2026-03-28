#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-west-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TRAIL_NAME="openclaw-bedrock-audit"
BUCKET_NAME="openclaw-audit-logs-${ACCOUNT_ID}-${REGION}"
DB_NAME="openclaw_audit"
TABLE_NAME="cloudtrail_bedrock"

echo "==> Setting up Bedrock audit logging"
echo "  Region:  ${REGION}"
echo "  Trail:   ${TRAIL_NAME}"
echo "  Bucket:  ${BUCKET_NAME}"

# 1. S3 bucket
echo "  → Creating S3 bucket: ${BUCKET_NAME}"
if [[ "$REGION" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
else
  aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi

aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"CloudTrailS3\",
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"cloudtrail.amazonaws.com\"},
    \"Action\": \"s3:GetBucketAcl\",
    \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}\"
  },{
    \"Sid\": \"CloudTrailWrite\",
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"cloudtrail.amazonaws.com\"},
    \"Action\": \"s3:PutObject\",
    \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/AWSLogs/${ACCOUNT_ID}/*\",
    \"Condition\": {\"StringEquals\": {\"s3:x-amz-acl\": \"bucket-owner-full-control\"}}
  }]
}"

# 2. CloudTrail trail (Bedrock events only)
echo "  → Creating CloudTrail trail: ${TRAIL_NAME}"
aws cloudtrail create-trail \
  --name "${TRAIL_NAME}" \
  --s3-bucket-name "${BUCKET_NAME}" \
  --region "${REGION}" \
  --no-is-multi-region-trail

aws cloudtrail put-event-selectors \
  --trail-name "${TRAIL_NAME}" \
  --region "${REGION}" \
  --advanced-event-selectors "[{
    \"Name\": \"BedrockEvents\",
    \"FieldSelectors\": [
      {\"Field\": \"eventCategory\", \"Equals\": [\"Management\"]},
      {\"Field\": \"eventSource\", \"Equals\": [\"bedrock.amazonaws.com\", \"bedrock-runtime.amazonaws.com\"]}
    ]
  }]"

aws cloudtrail start-logging --name "${TRAIL_NAME}" --region "${REGION}"

# 3. Athena database + table
echo "  → Creating Athena database and table"
ATHENA_OUTPUT="s3://${BUCKET_NAME}/athena-results/"

aws athena start-query-execution \
  --query-string "CREATE DATABASE IF NOT EXISTS ${DB_NAME}" \
  --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
  --region "${REGION}"

sleep 3

aws athena start-query-execution \
  --query-string "
CREATE EXTERNAL TABLE IF NOT EXISTS ${DB_NAME}.${TABLE_NAME} (
  eventVersion STRING, userIdentity STRUCT<type:STRING,principalId:STRING,arn:STRING,accountId:STRING>,
  eventTime STRING, eventSource STRING, eventName STRING, awsRegion STRING,
  sourceIPAddress STRING, userAgent STRING, requestParameters STRING, responseElements STRING,
  requestId STRING, eventId STRING, eventType STRING
)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
LOCATION 's3://${BUCKET_NAME}/AWSLogs/${ACCOUNT_ID}/CloudTrail/${REGION}/'
" \
  --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
  --region "${REGION}"

echo ""
echo "=== Audit Logging Configured ==="
echo "  Trail:    ${TRAIL_NAME}"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  Athena:   ${DB_NAME}.${TABLE_NAME}"
echo ""
echo "  Query example:"
echo "    SELECT eventtime, eventname, useridentity.arn"
echo "    FROM ${DB_NAME}.${TABLE_NAME}"
echo "    WHERE eventsource = 'bedrock-runtime.amazonaws.com'"
echo "    ORDER BY eventtime DESC LIMIT 20;"
echo "================================"
