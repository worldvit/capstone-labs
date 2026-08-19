#!/usr/bin/env bash
# ============================================================
# adopt.sh — 콘솔로 만든 리소스를 state 파일에 등록한다.
#
# 사용법:
#   cd ~/capstone-labs
#   bash adopt.sh            # 전체 확인만
#   bash adopt.sh --write    # 전체 기록
#   bash adopt.sh 5          # Lab 5 까지만 확인
#   bash adopt.sh 5 --write  # Lab 5 까지만 기록
#
# 왜 필요한가:
#   verify.sh 는 리소스를 ID로 조회한다. build.sh 로 만들면 ID가 자동
#   기록되지만, 콘솔로 만들면 그 기록이 없어 검사가 대부분 실패한다.
#   이 스크립트는 Name 태그로 리소스를 찾아 빈칸을 채운다.
#
#   저장소를 지우고 다시 clone 해도 이 스크립트만 돌리면 복구된다.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")"
source 00-common/bootstrap.sh
# bootstrap 이 set -euo pipefail 을 건다. 이 스크립트는 "못 찾음"이 정상
# 흐름이므로 errexit 를 끈다. 켜두면 첫 번째 없음에서 종료된다.
set +e

WRITE=0
UPTO=13
for a in "$@"; do
  case "$a" in
    --write) WRITE=1 ;;
    [0-9]|1[0-3]) UPTO="$a" ;;
    *) die "사용법: bash adopt.sh [랩번호] [--write]" ;;
  esac
done

FOUND=0; MISSING=0; MISSED_NAMES=""

# ------------------------------------------------------------
# 공통 헬퍼
# ------------------------------------------------------------
put() {  # put <키> <값> [부가설명]
  local key="$1" val="$2" note="${3:-}"
  if [ -z "$val" ] || [ "$val" = "None" ] || [ "$val" = "null" ]; then
    printf '  \033[31m없음\033[0m  %-18s %s\n' "$key" "$note"
    MISSING=$((MISSING+1)); MISSED_NAMES="$MISSED_NAMES $note"
    return 0
  fi
  printf '  \033[32m찾음\033[0m  %-18s %s\n' "$key" "$val"
  FOUND=$((FOUND+1))
  [ "$WRITE" = "1" ] && save_state "$key" "$val" || true
  return 0
}
q() { aws --region "$REGION" "$@" 2>/dev/null | tr -d '\r'; }

by_tag() {  # by_tag <서비스명령...> — 마지막 인자가 Name 값
  q "$@"
}

vpc_id()  { q ec2 describe-vpcs --filters "Name=tag:Name,Values=$1" --query 'Vpcs[0].VpcId' --output text; }
sn_id()   { q ec2 describe-subnets --filters "Name=tag:Name,Values=$1" --query 'Subnets[0].SubnetId' --output text; }
rt_id()   { q ec2 describe-route-tables --filters "Name=tag:Name,Values=$1" --query 'RouteTables[0].RouteTableId' --output text; }
sg_id()   { q ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId' --output text; }
nacl_id() { q ec2 describe-network-acls --filters "Name=tag:Name,Values=$1" --query 'NetworkAcls[0].NetworkAclId' --output text; }
nat_id()  { q ec2 describe-nat-gateways --filter "Name=tag:Name,Values=$1" "Name=state,Values=available" --query 'NatGateways[0].NatGatewayId' --output text; }
ec2_id()  { q ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[0].InstanceId | [0]' --output text; }
ec2_pub() { q ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[0].PublicIpAddress | [0]' --output text; }
ec2_pri() { q ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[0].PrivateIpAddress | [0]' --output text; }
vpce_id() { q ec2 describe-vpc-endpoints --filters "Name=tag:Name,Values=$1" --query 'VpcEndpoints[0].VpcEndpointId' --output text; }

banner "콘솔 리소스 등록  (Lab 1 ~ $UPTO)"

# ============================================================
# Lab 2 — VPC · 서브넷
# ============================================================
if [ "$UPTO" -ge 2 ]; then
  log "Lab 2  VPC · 서브넷"
  put VPC_SVC      "$(vpc_id "$N_VPC_SVC")"   "$N_VPC_SVC"
  put VPC_MGMT     "$(vpc_id "$N_VPC_MGMT")"  "$N_VPC_MGMT"
  put SN_SVC_PUB_A "$(sn_id "${PREFIX}-svc-pub-a")" "${PREFIX}-svc-pub-a"
fi

# ============================================================
# Lab 3 — 라우팅 · 보안 그룹 · NAT · NACL
# ============================================================
if [ "$UPTO" -ge 3 ]; then
  log "Lab 3  라우팅 · 보안 · NAT"
  put RT_SVC_PUB    "$(rt_id "${PREFIX}-rt-svc-pub")"    "${PREFIX}-rt-svc-pub"
  put RT_SVC_APP_A  "$(rt_id "${PREFIX}-rt-svc-app-a")"  "${PREFIX}-rt-svc-app-a"
  put RT_SVC_APP_C  "$(rt_id "${PREFIX}-rt-svc-app-c")"  "${PREFIX}-rt-svc-app-c"
  put RT_SVC_DB     "$(rt_id "${PREFIX}-rt-svc-db")"     "${PREFIX}-rt-svc-db"
  put RT_MGMT_PUB   "$(rt_id "${PREFIX}-rt-mgmt-pub")"   "${PREFIX}-rt-mgmt-pub"
  put RT_MGMT_APP_A "$(rt_id "${PREFIX}-rt-mgmt-app-a")" "${PREFIX}-rt-mgmt-app-a"
  put SG_ALB        "$(sg_id "$N_SG_ALB")"      "$N_SG_ALB"
  put SG_APP        "$(sg_id "$N_SG_APP")"      "$N_SG_APP"
  put SG_DB         "$(sg_id "$N_SG_DB")"       "$N_SG_DB"
  put SG_BASTION    "$(sg_id "$N_SG_BASTION")"  "$N_SG_BASTION"
  put NAT_SVC_A     "$(nat_id "${PREFIX}-rnat-svc")"  "${PREFIX}-rnat-svc"
  put NACL_SVC_APP  "$(nacl_id "${PREFIX}-nacl-svc-app")" "${PREFIX}-nacl-svc-app"

  MODE="$(q ec2 describe-nat-gateways --filter "Name=tag:Owner,Values=$PREFIX" \
    "Name=state,Values=available" --output json \
    | jq -r '[.NatGateways[] | .AvailabilityMode // "zonal"] | unique | .[0] // "unknown"')"
  put NAT_MODE_USED "$MODE" "NAT 모드"
fi

# ============================================================
# Lab 4 — EC2
# ============================================================
if [ "$UPTO" -ge 4 ]; then
  log "Lab 4  EC2"
  put BASTION_ID "$(ec2_id "$N_BASTION")" "$N_BASTION"
  put APP_A_ID   "$(ec2_id "$N_APP_A")"   "$N_APP_A"
  put APP_C_ID   "$(ec2_id "$N_APP_C")"   "$N_APP_C"
  put BASTION_IP "$(ec2_pub "$N_BASTION")" "Bastion 퍼블릭 IP"
  put APP_A_PIP  "$(ec2_pri "$N_APP_A")"   "app-a 프라이빗 IP"
  put AMI_ID "$(q ec2 describe-instances --filters "Name=tag:Name,Values=$N_APP_A" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[0].ImageId | [0]' --output text)" "app-a AMI"
fi

# ============================================================
# Lab 5 — VPC 엔드포인트 · TGW
# ============================================================
if [ "$UPTO" -ge 5 ]; then
  log "Lab 5  엔드포인트 · TGW"
  put VPCE_S3      "$(vpce_id "${PREFIX}-vpce-s3")"      "${PREFIX}-vpce-s3"
  put VPCE_SSM     "$(vpce_id "${PREFIX}-vpce-ssm")"     "${PREFIX}-vpce-ssm"
  put VPCE_SSMMSG  "$(vpce_id "${PREFIX}-vpce-ssmmessages")" "${PREFIX}-vpce-ssmmessages"
  put VPCE_EC2MSG  "$(vpce_id "${PREFIX}-vpce-ec2messages")" "${PREFIX}-vpce-ec2messages"
  put TGW_ID "$(q ec2 describe-transit-gateways \
    --filters "Name=tag:Name,Values=$N_TGW" "Name=state,Values=available" \
    --query 'TransitGateways[0].TransitGatewayId' --output text)" "$N_TGW"
fi

# ============================================================
# Lab 6 — S3
# ============================================================
if [ "$UPTO" -ge 6 ]; then
  log "Lab 6  S3"
  put BUCKET_WEB  "$(q s3api list-buckets --query "Buckets[?starts_with(Name,'${PREFIX}-web-')].Name | [0]"  --output text)" "${PREFIX}-web-계정번호"
  put BUCKET_LOGS "$(q s3api list-buckets --query "Buckets[?starts_with(Name,'${PREFIX}-logs-')].Name | [0]" --output text)" "${PREFIX}-logs-계정번호"
fi

# ============================================================
# Lab 7 — EFS
# ============================================================
if [ "$UPTO" -ge 7 ]; then
  log "Lab 7  EFS"
  put SG_EFS "$(sg_id "$N_SG_EFS")" "$N_SG_EFS"
  EFS="$(q efs describe-file-systems --query "FileSystems[?Name=='$N_EFS'].FileSystemId | [0]" --output text)"
  put EFS_ID "$EFS" "$N_EFS"
  if [ -n "$EFS" ] && [ "$EFS" != "None" ]; then
    put EFS_AP "$(q efs describe-access-points --file-system-id "$EFS" \
      --query 'AccessPoints[0].AccessPointId' --output text)" "EFS 액세스 포인트"
  fi
fi

# ============================================================
# Lab 8 — RDS / Aurora
# ============================================================
if [ "$UPTO" -ge 8 ]; then
  log "Lab 8  데이터베이스"
  CL="$(q rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" \
        --query 'DBClusters[0].DBClusterIdentifier' --output text)"
  if [ -n "$CL" ] && [ "$CL" != "None" ]; then
    put AURORA_CLUSTER   "$CL" "$N_AURORA_CLUSTER"
    put AURORA_WRITER_EP "$(q rds describe-db-clusters --db-cluster-identifier "$CL" --query 'DBClusters[0].Endpoint' --output text)" "writer"
    put AURORA_READER_EP "$(q rds describe-db-clusters --db-cluster-identifier "$CL" --query 'DBClusters[0].ReaderEndpoint' --output text)" "reader"
    put DB_MODE_USED "aurora" "DB 모드"
    put DB_SECRET_ARN "$(q rds describe-db-clusters --db-cluster-identifier "$CL" --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)" "시크릿"
  else
    ID="$(q rds describe-db-instances --db-instance-identifier "$N_RDS" \
          --query 'DBInstances[0].DBInstanceIdentifier' --output text)"
    put DB_IDENTIFIER "$ID" "$N_RDS"
    if [ -n "$ID" ] && [ "$ID" != "None" ]; then
      put DB_MODE_USED   "rds" "DB 모드"
      put DB_ENGINE_USED "$(q rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].Engine' --output text)" "엔진"
      put DB_PORT_USED   "$(q rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].Endpoint.Port' --output text)" "포트"
      put DB_MULTIAZ_USED "$(q rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].MultiAZ' --output text)" "다중 AZ"
      put DB_RETAIN_USED "$(q rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].BackupRetentionPeriod' --output text)" "백업 보존"
      put DB_SECRET_ARN  "$(q rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)" "시크릿"
    fi
  fi
fi

# ============================================================
# Lab 8.5 — 3계층
# ============================================================
if [ "$UPTO" -ge 8 ]; then
  log "Lab 8.5  3계층"
  put SG_WEB   "$(sg_id "${PREFIX}-sg-web")" "${PREFIX}-sg-web"
  put NGINX_ID "$(ec2_id "${PREFIX}-nginx")" "${PREFIX}-nginx"
  put NGINX_IP "$(ec2_pub "${PREFIX}-nginx")" "nginx 퍼블릭 IP"
fi

# ============================================================
# Lab 9 — 관측성
# ============================================================
if [ "$UPTO" -ge 9 ]; then
  log "Lab 9  관측성"
  put TRAIL_NAME "$(q cloudtrail describe-trails --trail-name-list "$N_TRAIL" \
    --query 'trailList[0].Name' --output text)" "$N_TRAIL"
  put SNS_ALERTS_ARN "$(q sns list-topics \
    --query "Topics[?ends_with(TopicArn,':$N_SNS_ALERTS')].TopicArn | [0]" --output text)" "$N_SNS_ALERTS"
  put DASHBOARD "$(q cloudwatch list-dashboards \
    --query "DashboardEntries[?DashboardName=='$N_DASHBOARD'].DashboardName | [0]" --output text)" "$N_DASHBOARD"
fi

# ============================================================
# Lab 10 — ALB · ASG
# ============================================================
if [ "$UPTO" -ge 10 ]; then
  log "Lab 10  ALB · ASG"
  ALBARN="$(q elbv2 describe-load-balancers --names "$N_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  put ALB_ARN "$ALBARN" "$N_ALB"
  put ALB_DNS "$(q elbv2 describe-load-balancers --names "$N_ALB" --query 'LoadBalancers[0].DNSName' --output text)" "ALB DNS"
  put TARGET_GROUP_ARN "$(q elbv2 describe-target-groups --names "$N_TG" --query 'TargetGroups[0].TargetGroupArn' --output text)" "$N_TG"
  put ASG_NAME "$(q autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$N_ASG" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)" "$N_ASG"
fi

# ============================================================
# Lab 11 — CloudFront · WAF
# ============================================================
if [ "$UPTO" -ge 11 ]; then
  log "Lab 11  CloudFront · WAF"
  CFID="$(q cloudfront list-distributions --query "DistributionList.Items[?Comment=='${PREFIX}-cdn'].Id | [0]" --output text)"
  put CLOUDFRONT_ID "$CFID" "설명이 ${PREFIX}-cdn 인 배포"
  if [ -n "$CFID" ] && [ "$CFID" != "None" ]; then
    put CLOUDFRONT_DOMAIN "$(q cloudfront list-distributions \
      --query "DistributionList.Items[?Id=='$CFID'].DomainName | [0]" --output text)" "배포 도메인"
  fi
  put OAC_ID "$(q cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='$N_OAC'].Id | [0]" --output text)" "$N_OAC"
  WAF="$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
    --query "WebACLs[?Name=='$N_WAF'].Id | [0]" --output text 2>/dev/null | tr -d '\r')"
  put WAF_ID "$WAF" "$N_WAF (us-east-1)"
  put WAF_ARN "$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
    --query "WebACLs[?Name=='$N_WAF'].ARN | [0]" --output text 2>/dev/null | tr -d '\r')" "WAF ARN"
fi

# ============================================================
# Lab 12 — 서버리스
# ============================================================
if [ "$UPTO" -ge 12 ]; then
  log "Lab 12  서버리스"
  put SQS_URL     "$(q sqs get-queue-url --queue-name "$N_SQS"     --query QueueUrl --output text)" "$N_SQS"
  put SQS_DLQ_URL "$(q sqs get-queue-url --queue-name "$N_SQS_DLQ" --query QueueUrl --output text)" "$N_SQS_DLQ"
  put SNS_EVENTS_ARN "$(q sns list-topics \
    --query "Topics[?ends_with(TopicArn,':$N_SNS_EVENTS')].TopicArn | [0]" --output text)" "$N_SNS_EVENTS"
  APIID="$(q apigatewayv2 get-apis --query "Items[?Name=='$N_APIGW'].ApiId | [0]" --output text)"
  put APIGW_ID "$APIID" "$N_APIGW"
  if [ -n "$APIID" ] && [ "$APIID" != "None" ]; then
    put APIGW_ENDPOINT "$(q apigatewayv2 get-api --api-id "$APIID" --query ApiEndpoint --output text)" "API 엔드포인트"
  fi
fi

# ============================================================
# Lab 13 — 백업
# ============================================================
if [ "$UPTO" -ge 13 ]; then
  log "Lab 13  백업"
  put BACKUP_PLAN_ID "$(q backup list-backup-plans \
    --query "BackupPlansList[?BackupPlanName=='$N_BACKUP_PLAN'].BackupPlanId | [0]" --output text)" "$N_BACKUP_PLAN"
fi

# ------------------------------------------------------------
# 마무리
# ------------------------------------------------------------
echo
log "찾음 $FOUND 개 / 없음 $MISSING 개"

if [ "$MISSING" -gt 0 ]; then
  echo
  warn "찾지 못한 리소스가 있습니다."
  log  "  아직 만들지 않은 랩의 것이면 정상입니다."
  log  "  이미 만들었는데 없다고 나오면 Name 태그를 확인하십시오:"
  for n in $MISSED_NAMES; do log "    $n"; done
fi

echo
if [ "$WRITE" = "1" ]; then
  ok "state 파일에 기록했습니다: $STATE_FILE"
  log "  이제 해당 랩의 verify.sh 를 실행하십시오."
else
  log "확인만 했습니다. 기록하려면 --write 를 붙이십시오:"
  log "  bash adopt.sh${UPTO:+ $UPTO} --write"
fi
