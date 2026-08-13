#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 10  ALB + Auto Scaling Group + EFS"

APP_PORT="${APP_PORT_USED:-8080}"
TG="${TARGET_GROUP_ARN:-none}"
ALB="${ALB_DNS:-invalid}"
log "  ALB: http://${ALB}/  (대상 포트 ${APP_PORT})"

# ---------- ALB ----------
check_eq "ALB active" "active" bash -c \
  "aws elbv2 describe-load-balancers --load-balancer-arns ${ALB_ARN:-none} --query 'LoadBalancers[0].State.Code' --output text"
check_eq "ALB가 2개 AZ에 배치" "2" bash -c \
  "aws elbv2 describe-load-balancers --load-balancer-arns ${ALB_ARN:-none} --query 'length(LoadBalancers[0].AvailabilityZones)' --output text"
check_eq "ALB는 인터넷 대면" "internet-facing" bash -c \
  "aws elbv2 describe-load-balancers --load-balancer-arns ${ALB_ARN:-none} --query 'LoadBalancers[0].Scheme' --output text"

# ---------- 대상 그룹 ----------
check_eq "대상 그룹 포트 ${APP_PORT}" "$APP_PORT" bash -c \
  "aws elbv2 describe-target-groups --target-group-arns $TG --query 'TargetGroups[0].Port' --output text"
check_eq "상태 검사 경로 /health" "/health" bash -c \
  "aws elbv2 describe-target-groups --target-group-arns $TG --query 'TargetGroups[0].HealthCheckPath' --output text"
check_eq "healthy 대상 2개 이상" "true" bash -c \
  "n=\$(aws elbv2 describe-target-health --target-group-arn $TG --query \"length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])\" --output text)
   [ \"\${n:-0}\" -ge 2 ] && echo true || echo false"
check_eq "대상이 2개 AZ에 분산" "2" bash -c \
  "aws elbv2 describe-target-health --target-group-arn $TG --query \"TargetHealthDescriptions[?TargetHealth.State=='healthy'].Target.AvailabilityZone\" --output text | tr '\t' '\n' | grep -v '^None\$' | sort -u | grep -c ."

# ---------- ASG ----------
check_eq "ASG desired=2" "2" bash -c \
  "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ASG_NAME:-none} --query 'AutoScalingGroups[0].DesiredCapacity' --output text"
check_eq "ASG max=4" "4" bash -c \
  "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ASG_NAME:-none} --query 'AutoScalingGroups[0].MaxSize' --output text"
check_eq "ASG가 2개 서브넷에 걸침" "2" bash -c \
  "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ASG_NAME:-none} --query 'AutoScalingGroups[0].VPCZoneIdentifier' --output text | tr ',' '\n' | grep -c ."
check_eq "상태 검사 유형 ELB" "ELB" bash -c \
  "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ASG_NAME:-none} --query 'AutoScalingGroups[0].HealthCheckType' --output text"
check_eq "조정 정책 존재" "true" bash -c \
  "n=\$(aws autoscaling describe-policies --auto-scaling-group-name ${ASG_NAME:-none} --query 'length(ScalingPolicies)' --output text)
   [ \"\${n:-0}\" -ge 1 ] && echo true || echo false"

# ---------- 보안 그룹 ----------
check_eq "app-sg ${APP_PORT} 가 alb-sg 참조" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --output json \
   | jq -r --argjson p $APP_PORT '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==\$p) | .UserIdGroupPairs[].GroupId] | index(\"${SG_ALB:-none}\") != null'"
check_eq "app-sg ${APP_PORT} 에 CIDR 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --output json \
   | jq --argjson p $APP_PORT '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==\$p) | .IpRanges[]] | length'"

# ---------- 실제 응답 ----------
check "ALB 상태 검사 경로 응답" bash -c \
  "curl -fsS --max-time 15 http://${ALB}/health | grep -q OK"
check "ALB 를 통해 JSP 렌더링" bash -c \
  "curl -fsS --max-time 20 http://${ALB}/ | grep -q APP_INSTANCE"
check_eq "ASG가 만든 노드가 응답" "ASG" bash -c \
  "curl -fsS --max-time 20 http://${ALB}/ | sed -n 's|.*LAUNCHED_BY</th><td>\([^<]*\).*|\1|p' | head -1"
check_eq "DB 계층 조회 성공" "OK" bash -c \
  "curl -fsS --max-time 25 http://${ALB}/ | sed -n 's|.*DB_STATUS</th><td>\([^<]*\).*|\1|p' | head -1"

# ---------- EFS 공유 ----------
# 모든 노드가 같은 EFS 파일을 본다면 공유 스토리지가 동작하는 것이다.
if [ -n "${EFS_ID:-}" ]; then
  check_eq "모든 노드가 같은 EFS 파일을 봄" "1" bash -c \
    "for i in \$(seq 1 8); do
       curl -s --max-time 15 -H 'Connection: close' http://${ALB}/ \
       | sed -n 's|.*EFS_SHARED_NOTE</th><td>\([^<]*\).*|\1|p'
     done | sort -u | grep -c ."
fi

# ---------- 다중 AZ 응답 ----------
check_eq "두 AZ의 노드가 번갈아 응답" "2" bash -c \
  "for i in \$(seq 1 10); do
     curl -s --max-time 15 -H 'Connection: close' http://${ALB}/ \
     | sed -n 's|.*APP_AZ</th><td>\([^<]*\).*|\1|p'
   done | sort -u | grep -c ."

check_summary
