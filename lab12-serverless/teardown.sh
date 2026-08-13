#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 12 teardown"
confirm_destroy "SNS·SQS·Lambda·API Gateway를 삭제합니다."

[ -n "${BUCKET_WEB:-}" ] && soft aws s3api put-bucket-notification-configuration --bucket "$BUCKET_WEB" --notification-configuration '{}'
[ -n "${APIGW_ID:-}" ] && soft aws apigatewayv2 delete-api --api-id "$APIGW_ID"
for m in $(aws lambda list-event-source-mappings --function-name "$N_LAMBDA" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  soft aws lambda delete-event-source-mapping --uuid "$m"
done
soft aws lambda delete-function --function-name "$N_LAMBDA"
for arn in $(aws iam list-attached-role-policies --role-name "$N_ROLE_LAMBDA" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  soft aws iam detach-role-policy --role-name "$N_ROLE_LAMBDA" --policy-arn "$arn"
done
soft aws iam delete-role --role-name "$N_ROLE_LAMBDA"
[ -n "${SQS_URL:-}" ] && soft aws sqs delete-queue --queue-url "$SQS_URL"
[ -n "${SQS_DLQ_URL:-}" ] && soft aws sqs delete-queue --queue-url "$SQS_DLQ_URL"
[ -n "${SNS_EVENTS_ARN:-}" ] && soft aws sns delete-topic --topic-arn "$SNS_EVENTS_ARN"

for k in SQS_URL SQS_ARN SQS_DLQ_URL SQS_DLQ_ARN SNS_EVENTS_ARN LAMBDA_ARN LAMBDA_ROLE_ARN APIGW_ID APIGW_ENDPOINT LAB12_DONE; do drop_state "$k"; done
ok "Lab 12 teardown 완료"
