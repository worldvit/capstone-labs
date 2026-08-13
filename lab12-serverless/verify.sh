#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 12  SNS · SQS · Lambda · API Gateway"

log "  API: ${APIGW_ENDPOINT:-미확인}"

# ---------- 큐 ----------
check "SQS 메인 큐 존재" aws sqs get-queue-attributes --queue-url "${SQS_URL:-none}" --attribute-names QueueArn
check "SQS DLQ 존재" aws sqs get-queue-attributes --queue-url "${SQS_DLQ_URL:-none}" --attribute-names QueueArn
check_eq "메인 큐에 DLQ 연결(maxReceiveCount=3)" "3" bash -c \
  "aws sqs get-queue-attributes --queue-url ${SQS_URL:-none} --attribute-names RedrivePolicy --output json \
   | jq -r '.Attributes.RedrivePolicy | fromjson | .maxReceiveCount'"

# ---------- SNS ----------
check_eq "SNS → SQS 구독 1개" "1" bash -c \
  "aws sns list-subscriptions-by-topic --topic-arn ${SNS_EVENTS_ARN:-none} --query \"length(Subscriptions[?Protocol=='sqs'])\" --output text"
check "S3 이벤트 알림 구성됨" bash -c \
  "aws s3api get-bucket-notification-configuration --bucket ${BUCKET_WEB:-none} --output json \
   | jq -e '.TopicConfigurations | length > 0'"

# ---------- Lambda ----------
check_eq "Lambda Active" "Active" bash -c \
  "aws lambda get-function --function-name $N_LAMBDA --query 'Configuration.State' --output text"
check_eq "SQS 이벤트 소스 매핑 Enabled" "Enabled" bash -c \
  "aws lambda list-event-source-mappings --function-name $N_LAMBDA --query 'EventSourceMappings[0].State' --output text"

# ---------- API Gateway ----------
check "API Gateway 존재" aws apigatewayv2 get-api --api-id "${APIGW_ID:-none}"
check "API 엔드포인트 200 응답" bash -c \
  "curl -fsS --max-time 20 ${APIGW_ENDPOINT:-http://invalid}/ | grep -q capstone"

# ---------- CloudFront /api/* (Lab 11 구성 시) ----------
if [ -n "${CLOUDFRONT_ID:-}" ]; then
  check_eq "CloudFront에 /api/* 경로 존재" "1" bash -c \
    "aws cloudfront get-distribution --id ${CLOUDFRONT_ID} --output json \
     | jq '[.Distribution.DistributionConfig.CacheBehaviors.Items[]? | select(.PathPattern==\"/api/*\")] | length'"
  # 전파 전에는 404가 날 수 있으므로 배포가 Deployed 일 때만 확인한다.
  ST="$(_q aws cloudfront get-distribution --id "${CLOUDFRONT_ID}" --query 'Distribution.Status' --output text)"
  if [ "$ST" = "Deployed" ]; then
    check "CloudFront 경유 /api/ 응답" bash -c \
      "curl -fsS --max-time 25 https://${CLOUDFRONT_DOMAIN:-invalid}/api/ | grep -q capstone"
  else
    log "  (배포 전파 중 — CloudFront 경유 /api/ 검사는 건너뜁니다)"
  fi
fi

# ---------- 파이프라인 종단 시험 ----------
# 구성 요소가 각각 존재한다는 것과 메시지가 실제로 흐르는 것은 다르다.
if [ "${PIPELINE_TEST:-1}" = "1" ] && [ -n "${BUCKET_WEB:-}" ]; then
  pipeline_e2e() {
    local tag tmp since msgs
    tag="capstone-e2e-$(date +%s)"
    tmp="$(mktemp)"; printf '%s\n' "$tag" > "$tmp"
    since=$(( ($(date +%s) - 60) * 1000 ))
    aws s3 cp "$tmp" "s3://${BUCKET_WEB}/uploads/${tag}.txt" >/dev/null 2>&1 \
      || { rm -f "$tmp"; echo UPLOAD_FAIL; return 0; }
    rm -f "$tmp"

    # Lambda 는 파일 내용을 읽지 않는다. S3 이벤트 JSON 에 담긴 '객체 키'로 찾아야 한다.
    # filter-pattern 은 하이픈이 섞인 문자열을 다루기 까다로우므로 받아서 직접 대조한다.
    for _ in $(seq 1 15); do
      sleep 5
      msgs="$(aws logs filter-log-events --log-group-name "/aws/lambda/${N_LAMBDA}" \
              --start-time "$since" --query 'events[].message' --output text 2>/dev/null || true)"
      case "$msgs" in
        *"uploads/${tag}.txt"*) echo OK; return 0 ;;
      esac
    done
    echo NOT_DELIVERED
  }
  check_eq "S3 → SNS → SQS → Lambda 종단 전달" "OK" pipeline_e2e
else
  log "  (PIPELINE_TEST=0 이라 종단 시험을 건너뜁니다)"
fi

# ---------- DLQ 동작 (선택) ----------
if [ "${DLQ_TEST:-0}" = "1" ]; then
  dlq_check() {
    # Lambda 가 처리하지 못하는 메시지를 넣어 3회 실패 후 DLQ 로 가는지 본다.
    aws sqs send-message --queue-url "${SQS_URL}" \
      --message-body '{"capstone":"poison","force_error":true}' >/dev/null 2>&1 || { echo SEND_FAIL; return 0; }
    for _ in $(seq 1 20); do
      sleep 10
      n="$(aws sqs get-queue-attributes --queue-url "${SQS_DLQ_URL}" \
           --attribute-names ApproximateNumberOfMessages \
           --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null || echo 0)"
      [ "${n:-0}" -ge 1 ] && { echo OK; return 0; }
    done
    echo NO_DLQ_MESSAGE
  }
  check_eq "실패 메시지가 DLQ로 이동" "OK" dlq_check
else
  log "  (DLQ_TEST=1 로 실행하면 실패 메시지의 DLQ 이동까지 확인합니다)"
fi

check_summary
