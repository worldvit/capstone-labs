#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"

MODE="${DB_MODE_USED:-$DB_MODE}"
check_begin "Lab 8  데이터베이스 다중 AZ ($MODE 모드)"

DB_PORT="${DB_PORT_USED:-}"
if [ -z "$DB_PORT" ]; then
  case "${DB_ENGINE_USED:-$RDS_ENGINE}" in
    postgres|aurora-postgresql) DB_PORT=5432 ;;
    *)                          DB_PORT=3306 ;;
  esac
fi
log "  엔진 ${DB_ENGINE_USED:-미확인} / 포트 $DB_PORT"

# ---------- SSM으로 App 서버에서 실제 도달 여부 확인 ----------
ssm_run() { # <instance-id> <shell command> → 표준 출력
  local iid="$1" cmd="$2" cid st
  cid="$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
        --parameters "$(jq -nc --arg c "$cmd" '{commands:[$c]}')" \
        --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  sleep 3   # send-command 직후에는 호출 기록이 아직 없다
  for _ in $(seq 1 20); do
    # 조회 실패(InvocationDoesNotExist)는 정상 흐름이므로 종료 코드를 삼킨다.
    # || true 가 없으면 set -e 가 함수를 죽여 검사 결과가 빈 값이 된다.
    st="$(aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" \
          --query 'CommandInvocations[0].Status' --output text 2>/dev/null || true)"
    case "$st" in
      Success) aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" --details \
                 --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>/dev/null || true
               return 0 ;;
      Failed|TimedOut|Cancelled) return 1 ;;
    esac
    sleep 3
  done
  return 1
}

db_reach() { # <instance-id> <endpoint> → REACH / NO_DNS / NO_TCP
  local iid="$1" ep="$2" out
  [ -n "$ep" ] && [ "$ep" != "none" ] || { echo NO_ENDPOINT; return 0; }
  out="$(ssm_run "$iid" \
    "getent hosts $ep >/dev/null 2>&1 || { echo NO_DNS; exit 0; }; timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$ep/$DB_PORT' 2>/dev/null && echo REACH || echo NO_TCP" || true)"
  case "$out" in
    *REACH*)  echo REACH ;;
    *NO_DNS*) echo NO_DNS ;;
    *NO_TCP*) echo NO_TCP ;;
    *)        echo UNKNOWN ;;
  esac
}

# ============================================================
if [ "$MODE" = "rds" ]; then
# ============================================================
  DBID="${DB_IDENTIFIER:-$N_RDS}"
  check_eq "RDS 인스턴스 available" "available" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].DBInstanceStatus' --output text"
  check_eq "엔진 ${DB_ENGINE_USED:-$RDS_ENGINE}" "${DB_ENGINE_USED:-$RDS_ENGINE}" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].Engine' --output text"
  check_eq "저장 시 암호화" "True" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].StorageEncrypted' --output text"
  check_eq "퍼블릭 접근 불가" "False" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].PubliclyAccessible' --output text"
  check_eq "DB 서브넷 그룹 연결" "$N_DB_SUBNET_GROUP" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text"
  check_eq "DB 서브넷 그룹이 2개 AZ에 걸침" "2" bash -c \
    "aws rds describe-db-subnet-groups --db-subnet-group-name $N_DB_SUBNET_GROUP --query 'DBSubnetGroups[0].Subnets[].SubnetAvailabilityZone.Name' --output text | tr '\t' '\n' | sort -u | grep -c ."
  check_eq "db-sg만 연결" "${SG_DB:-none}" bash -c \
    "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text"

  # 다중 AZ 여부 — Free Tier가 거부했다면 단일 AZ로 만들어진다.
  if [ "${DB_MULTIAZ_USED:-1}" = "1" ]; then
    check_eq "다중 AZ 배포 활성" "True" bash -c \
      "aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].MultiAZ' --output text"
    check_eq "대기 인스턴스가 다른 AZ" "true" bash -c \
      "p=\$(aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].AvailabilityZone' --output text)
       s=\$(aws rds describe-db-instances --db-instance-identifier $DBID --query 'DBInstances[0].SecondaryAvailabilityZone' --output text)
       [ -n \"\$s\" ] && [ \"\$s\" != None ] && [ \"\$p\" != \"\$s\" ] && echo true || echo false"
  else
    log "  (Free Tier 제약으로 단일 AZ 생성 — 다중 AZ 검사를 건너뜁니다)"
  fi

  check "Secrets Manager 관리형 자격 증명" aws secretsmanager describe-secret --secret-id "${DB_SECRET_ARN:-none}"

# ============================================================
else
# ============================================================
  CID="${AURORA_CLUSTER:-$N_AURORA_CLUSTER}"
  check_eq "클러스터 available" "available" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier $CID --query 'DBClusters[0].Status' --output text"
  check_eq "인스턴스 2개(라이터+리더)" "2" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier $CID --query 'length(DBClusters[0].DBClusterMembers)' --output text"
  check_eq "라이터 1개만 존재" "1" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier $CID --query 'length(DBClusters[0].DBClusterMembers[?IsClusterWriter])' --output text"
  check_eq "두 인스턴스가 서로 다른 AZ" "2" bash -c \
    "aws rds describe-db-instances --filters Name=db-cluster-id,Values=$CID --query 'DBInstances[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | grep -c ."
  check_eq "저장 시 암호화" "True" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier $CID --query 'DBClusters[0].StorageEncrypted' --output text"
  check_eq "퍼블릭 접근 불가" "0" bash -c \
    "aws rds describe-db-instances --filters Name=db-cluster-id,Values=$CID --query 'length(DBInstances[?PubliclyAccessible])' --output text"
  check_eq "db-sg만 연결" "${SG_DB:-none}" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier $CID --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text"
  check "Secrets Manager 관리형 자격 증명" aws secretsmanager describe-secret --secret-id "${DB_SECRET_ARN:-none}"
fi

# ---------- 공통: 보안 그룹과 실제 도달성 ----------
check_eq "db-sg $DB_PORT 가 app-sg 참조" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_DB:-none} --output json \
   | jq -r --argjson p $DB_PORT '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==\$p) | .UserIdGroupPairs[].GroupId] | index(\"${SG_APP:-none}\") != null'"
check_eq "db-sg $DB_PORT 에 CIDR 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_DB:-none} --output json \
   | jq --argjson p $DB_PORT '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==\$p) | .IpRanges[]] | length'"

# 클러스터가 available 이어도 앱에서 못 닿을 수 있다(SG 체인·DNS·서브넷 문제).
# 자격 증명 없이 TCP 도달만 확인한다.
if [ "${DB_REACH_CHECK:-1}" = "1" ] && [ -n "${APP_A_ID:-}" ]; then
  check_eq "App 서버 → DB $DB_PORT 도달" "REACH" db_reach "${APP_A_ID}" "${AURORA_WRITER_EP:-none}"
  if [ "$MODE" = "aurora" ] && [ -n "${AURORA_READER_EP:-}" ]; then
    check_eq "App 서버 → 리더 엔드포인트 도달" "REACH" db_reach "${APP_A_ID}" "${AURORA_READER_EP}"
  fi
else
  log "  (DB_REACH_CHECK=0 이거나 App 서버가 없어 도달성 검사를 건너뜁니다)"
fi

# Bastion(관리 VPC)에서는 닿지 않아야 정상이다. db-sg가 app-sg만 허용하기 때문.
if [ "${DB_REACH_CHECK:-1}" = "1" ] && [ -n "${BASTION_ID:-}" ]; then
  bastion_blocked() {
    local r
    r="$(db_reach "${BASTION_ID}" "${AURORA_WRITER_EP:-none}")"
    case "$r" in REACH) echo REACH ;; *) echo BLOCKED ;; esac
  }
  check_eq "Bastion → DB 차단 확인(의도된 거부)" "BLOCKED" bastion_blocked
fi

check_summary
