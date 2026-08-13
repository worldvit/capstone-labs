#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 9  관측성 3종 (CloudWatch · CloudTrail · Flow Logs)"

check_eq "CloudTrail 로깅 활성" "True" bash -c \
  "aws cloudtrail get-trail-status --name ${TRAIL_NAME:-none} --query IsLogging --output text"
check_eq "CloudTrail 다중 리전" "True" bash -c \
  "aws cloudtrail get-trail --name ${TRAIL_NAME:-none} --query 'Trail.IsMultiRegionTrail' --output text"
check_eq "로그 파일 검증 활성" "True" bash -c \
  "aws cloudtrail get-trail --name ${TRAIL_NAME:-none} --query 'Trail.LogFileValidationEnabled' --output text"
check_eq "VPC Flow Logs 2개 ACTIVE" "2" bash -c \
  "aws ec2 describe-flow-logs --filter Name=resource-id,Values=${VPC_SVC:-none},${VPC_MGMT:-none} --query \"length(FlowLogs[?FlowLogStatus=='ACTIVE'])\" --output text"
check_eq "Flow Logs 트래픽 유형 ALL" "ALL" bash -c \
  "aws ec2 describe-flow-logs --filter Name=resource-id,Values=${VPC_SVC:-none} --query 'FlowLogs[0].TrafficType' --output text"
check "Flow Logs 로그 그룹 존재" bash -c \
  "aws logs describe-log-groups --log-group-name-prefix $N_LOGGROUP_FLOW --query 'length(logGroups)' --output text | grep -qv '^0$'"
check_eq "경보 4개 이상 (3계층 + DB)" "true" bash -c \
  "n=\$(aws cloudwatch describe-alarms --alarm-name-prefix $PREFIX --query 'length(MetricAlarms)' --output text); [ \"\$n\" -ge 4 ] && echo true || echo false"
check "Web 계층(nginx) 경보 존재" bash -c \
  "aws cloudwatch describe-alarms --alarm-names ${PREFIX}-nginx-cpu-high --query 'length(MetricAlarms)' --output text | grep -q '^1$'"
check "DB 경보 존재" bash -c \
  "aws cloudwatch describe-alarms --alarm-names ${PREFIX}-db-cpu-high --query 'length(MetricAlarms)' --output text | grep -q '^1$'"

# 로그 그룹만 있고 데이터가 없으면 관측성이 아니다. 실제 수집 여부를 본다.
# --max-items 는 페이지네이션 옵션이라 length() 와 함께 쓰면 값이 어긋난다. 쓰지 않는다.
count_streams() { # <로그그룹>
  aws logs describe-log-streams --log-group-name "$1" \
    --query 'logStreams[].logStreamName' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -c . || echo 0
}
check_eq "Flow Logs 스트림 수신" "true" bash -c \
  "n=\$(aws logs describe-log-streams --log-group-name $N_LOGGROUP_FLOW --query 'logStreams[].logStreamName' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -c .)
   [ \"\${n:-0}\" -ge 1 ] && echo true || echo false"
check_eq "애플리케이션 로그 스트림 수신 (nginx/tomcat)" "true" bash -c \
  "n=\$(aws logs describe-log-streams --log-group-name $N_LOGGROUP_APP --query 'logStreams[].logStreamName' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -c .)
   [ \"\${n:-0}\" -ge 1 ] && echo true || echo false"
# 스트림이 있어도 이벤트가 비어 있을 수 있다. 실제 로그 이벤트까지 확인한다.
check_eq "nginx 로그 이벤트 존재" "true" bash -c \
  "s=\$(aws logs describe-log-streams --log-group-name $N_LOGGROUP_APP --query \"logStreams[?contains(logStreamName,'nginx')].logStreamName | [0]\" --output text 2>/dev/null)
   [ -n \"\$s\" ] && [ \"\$s\" != None ] || { echo false; exit 0; }
   n=\$(aws logs get-log-events --log-group-name $N_LOGGROUP_APP --log-stream-name \"\$s\" --limit 5 --query 'length(events)' --output text 2>/dev/null || echo 0)
   [ \"\${n:-0}\" -ge 1 ] && echo true || echo false"
check_eq "CloudWatch Agent 사용자 지정 지표 수신" "true" bash -c \
  "n=\$(aws cloudwatch list-metrics --namespace Capstone --metric-name MemoryUtilization --query 'length(Metrics)' --output text 2>/dev/null || echo 0)
   [ \"\${n:-0}\" -ge 1 ] && echo true || echo false"
check "SNS 경보 주제 존재" aws sns get-topic-attributes --topic-arn "${SNS_ALERTS_ARN:-none}"
check "대시보드 존재" aws cloudwatch get-dashboard --dashboard-name "${DASHBOARD:-none}"
check_summary
