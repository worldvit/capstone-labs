#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 9 teardown"
confirm_destroy "CloudTrail·Flow Logs·경보·대시보드를 삭제합니다."

soft aws cloudtrail stop-logging --name "${TRAIL_NAME:-$N_TRAIL}"
soft aws cloudtrail delete-trail --name "${TRAIL_NAME:-$N_TRAIL}"
for v in "${VPC_SVC:-}" "${VPC_MGMT:-}"; do
  [ -n "$v" ] || continue
  for f in $(aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$v" --query 'FlowLogs[].FlowLogId' --output text 2>/dev/null); do
    soft aws ec2 delete-flow-logs --flow-log-ids "$f"; log "Flow Log 삭제 $f"
  done
done
ALARMS="$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null)"
[ -n "$ALARMS" ] && soft aws cloudwatch delete-alarms --alarm-names $ALARMS
soft aws cloudwatch delete-dashboards --dashboard-names "${DASHBOARD:-$N_DASHBOARD}"
for LG in "$N_LOGGROUP_FLOW" "$N_LOGGROUP_APP"; do soft aws logs delete-log-group --log-group-name "$LG"; done
soft aws iam delete-role-policy --role-name "$N_ROLE_FLOWLOG" --policy-name flowlogs-write
soft aws iam delete-role --role-name "$N_ROLE_FLOWLOG"
[ -n "${SNS_ALERTS_ARN:-}" ] && soft aws sns delete-topic --topic-arn "$SNS_ALERTS_ARN"

for k in TRAIL_NAME SNS_ALERTS_ARN FLOWLOG_ROLE_ARN DASHBOARD DB_ALARM_DIM \
         CWAGENT_CMD_app CWAGENT_CMD_web LAB09_DONE; do drop_state "$k"; done
ok "Lab 9 teardown 완료"
