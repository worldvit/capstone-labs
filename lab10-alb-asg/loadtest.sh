#!/usr/bin/env bash
# loadtest.sh — ASG 확장을 유발하고 그 과정을 관찰한다.
#
#   bash lab10-alb-asg/loadtest.sh          부하 + 관찰
#   bash lab10-alb-asg/loadtest.sh watch    관찰만
#   bash lab10-alb-asg/loadtest.sh stop     부하 중지
#   bash lab10-alb-asg/loadtest.sh check    조정 준비 상태 점검
#   bash lab10-alb-asg/loadtest.sh manual 3 수동으로 desired 변경(시연용)
#
# 조정이 늦는 원인은 대개 둘이다.
#   1) 조정 정책이 없다 (ASG 생성 직후 ServiceLinkedRoleFailure 로 실패했을 수 있다)
#   2) 기본 모니터링(5분)이라 경보 3회 연속 조건이 15분 걸린다
# check 로 먼저 확인하십시오.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  printf '[X] source 하지 마십시오.  올바른 사용:  bash %s\n' "${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi
source "$(dirname "$0")/../00-common/bootstrap.sh"

# 진단·관찰 스크립트는 조회 하나가 실패해도 끝까지 돌아야 한다.
# (bootstrap 의 set -euo pipefail 이 조용한 종료를 일으켰다)
set +e
set +o pipefail

ASG="${ASG_NAME:-$N_ASG}"
TG="${TARGET_GROUP_ARN:-}"

asg_nodes() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep . || true
}

# 조정을 좌우하는 조건을 한눈에 보여준다.
check_readiness() {
  banner "조정 준비 상태 점검"
  local n pol mon lt ver
  n="$(_q aws autoscaling describe-policies --auto-scaling-group-name "$ASG" --query 'length(ScalingPolicies)' --output text)"
  if [ "${n:-0}" -ge 1 ]; then
    ok "조정 정책 ${n}개"
    aws autoscaling describe-policies --auto-scaling-group-name "$ASG" \
      --query 'ScalingPolicies[].{정책:PolicyName,유형:PolicyType,목표CPU:TargetTrackingConfiguration.TargetValue,워밍업:EstimatedInstanceWarmup}' \
      --output table 2>/dev/null | sed 's/^/    /'
  else
    err "조정 정책이 없습니다 — 이것이 확장되지 않는 첫 번째 원인입니다"
    err "  해결: bash lab10-alb-asg/build.sh  (ASG 생성 직후에는 역할 준비로 실패할 수 있습니다)"
  fi

  lt="$(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
        --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateName' --output text)"
  ver="$(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
        --query 'AutoScalingGroups[0].LaunchTemplate.Version' --output text)"
  mon="$(_q aws ec2 describe-launch-template-versions --launch-template-name "$lt" \
        --versions '$Default' --query 'LaunchTemplateVersions[0].LaunchTemplateData.Monitoring.Enabled' --output text)"
  if [ "$mon" = "True" ]; then
    ok "세부 모니터링 활성 — 지표 1분 간격, 약 3분이면 반응"
  else
    warn "기본 모니터링(5분) — 경보 3회 연속 조건에 최소 15분 걸립니다"
    warn "  해결: DETAILED_MONITORING=true bash lab10-alb-asg/build.sh 후 REFRESH_ASG=1 로 노드 교체"
  fi

  # 실행 중인 인스턴스의 실제 모니터링 상태(템플릿과 다를 수 있다)
  local ids dm
  ids="$(asg_nodes | tr '\n' ' ')"
  if [ -n "$ids" ]; then
    dm="$(_q aws ec2 describe-instances --instance-ids $ids --query 'Reservations[].Instances[].Monitoring.State' --output text)"
    printf '    실행 중 노드 모니터링: %s\n' "${dm:-확인불가}"
    case "$dm" in
      *disabled*) warn "  일부 노드가 기본 모니터링입니다. REFRESH_ASG=1 로 교체해야 반영됩니다." ;;
    esac
  fi

  local cd
  cd="$(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'AutoScalingGroups[0].DefaultCooldown' --output text)"
  log "  기본 쿨다운: ${cd:-?}초 / max: $(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'AutoScalingGroups[0].MaxSize' --output text)"
}

# 현재 상태 한 줄 — CPU와 경보 상태까지 함께 본다.
show_state() {
  local desired inservice healthy cpu alarms
  desired="$(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
             --query 'AutoScalingGroups[0].DesiredCapacity' --output text)"
  inservice="$(asg_nodes | grep -c .)"
  healthy="$(_q aws elbv2 describe-target-health --target-group-arn "$TG" \
             --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  # ASG 전체 평균 CPU — 대상 추적이 보는 값과 같은 지표
  cpu="$(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
        --dimensions "Name=AutoScalingGroupName,Value=$ASG" \
        --start-time "$(date -u -d '-6 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-6M +%Y-%m-%dT%H:%M:%SZ)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Average --output json 2>/dev/null \
      | jq -r '.Datapoints | if length==0 then "-" else (sort_by(.Timestamp)|last|.Average|.*10|round|./10|tostring) end')"
  # 대상 추적이 자동 생성한 경보의 상태
  alarms="$(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${ASG}" \
           --query 'MetricAlarms[].StateValue' --output text 2>/dev/null | tr '\t' '/' )"
  printf '  %s  desired=%-2s InService=%-2s healthy=%-2s CPU=%-6s 경보=%s\n' \
    "$(date +%H:%M:%S)" "${desired:-?}" "${inservice:-0}" "${healthy:-0}" "${cpu:--}" "${alarms:-없음}"
}

case "${1:-run}" in
  check) check_readiness; exit 0 ;;
  stop)
    banner "부하 중지"
    for id in $(asg_nodes); do
      aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "$(jq -nc '{commands:["pkill -f stress-ng; pkill -f \"dd if=/dev/zero\"; true"]}')" \
        >/dev/null 2>&1 && ok "부하 중지: $id"
    done
    log "축소는 확장보다 느립니다(기본 15분). 즉시 줄이려면:"
    log "  bash $0 manual 2"
    exit 0 ;;
  watch)
    banner "ASG 상태 관찰 (Ctrl+C 로 종료)"
    while true; do show_state; sleep 20; done ;;
  manual)
    N="${2:-3}"
    banner "수동 조정 — desired=$N"
    warn "자동 조정을 기다릴 시간이 없을 때 쓰는 시연용입니다."
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
      --desired-capacity "$N" --honor-cooldown 2>/dev/null \
      || aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity "$N"
    ok "desired=$N 설정. 새 노드 준비까지 3~5분."
    for i in $(seq 1 20); do show_state; sleep 20; done
    exit 0 ;;
esac

check_readiness

banner "부하 시험"
NODES="$(asg_nodes)"
[ -n "$NODES" ] || die "InService 노드가 없습니다."
log "대상 노드: $(echo "$NODES" | tr '\n' ' ')"

CMD='(command -v stress-ng >/dev/null || dnf -y install stress-ng >/dev/null 2>&1) ; \
     if command -v stress-ng >/dev/null; then \
       nohup stress-ng --cpu 0 --timeout 1200s >/dev/null 2>&1 & \
     else \
       for i in $(seq 1 $(nproc)); do nohup dd if=/dev/zero of=/dev/null >/dev/null 2>&1 & done; \
       nohup bash -c "sleep 1200; pkill -f \"dd if=/dev/zero\"" >/dev/null 2>&1 & \
     fi ; echo started'

for id in $NODES; do
  aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg c "$CMD" '{commands:[$c]}')" >/dev/null 2>&1 \
    && ok "부하 시작: $id" || warn "부하 시작 실패: $id"
done

banner "관찰"
log "  경보가 ALARM 으로 바뀌면 곧 desired 가 오릅니다."
log "  세부 모니터링이면 3~5분, 기본 모니터링이면 15분 이상 걸립니다."
log "  중지: bash $0 stop"
printf '\n'
for i in $(seq 1 45); do show_state; sleep 20; done
printf '\n'
log "관찰 종료.  중지: bash $0 stop"
