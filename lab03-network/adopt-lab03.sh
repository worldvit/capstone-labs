#!/usr/bin/env bash
# ============================================================
# adopt-lab03.sh — 콘솔로 만든 Lab 3 리소스를 state 파일에 등록한다.
#
# 사용법:
#   cd ~/capstone-labs
#   bash lab03-network/adopt-lab03.sh          # 확인만
#   bash lab03-network/adopt-lab03.sh --write  # state 파일에 기록
#
# verify.sh 는 리소스 ID를 state 파일에서 읽는다. build.sh 로 만들면
# 자동으로 채워지지만, 콘솔로 만들면 비어 있어 검사가 모두 실패한다.
# 이 스크립트는 Name 태그로 리소스를 찾아 그 빈칸을 채운다.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source 00-common/bootstrap.sh

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

banner "Lab 3 콘솔 리소스 등록"

FOUND=0
MISSING=0

# by_name <키> <설명> <조회명령...>
by_name() {
  local key="$1" desc="$2"; shift 2
  local id
  id="$("$@" 2>/dev/null | tr -d '\r')"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    printf '  \033[31m없음\033[0m  %-16s %s\n' "$key" "$desc"
    MISSING=$((MISSING+1))
    return 1
  fi
  printf '  \033[32m찾음\033[0m  %-16s %s\n' "$key" "$id"
  FOUND=$((FOUND+1))
  [ "$WRITE" = "1" ] && save_state "$key" "$id"
  return 0
}

rt()   { aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$1" \
           --query 'RouteTables[0].RouteTableId' --output text --region "$REGION"; }
sg()   { aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" \
           --query 'SecurityGroups[0].GroupId' --output text --region "$REGION"; }
nacl() { aws ec2 describe-network-acls --filters "Name=tag:Name,Values=$1" \
           --query 'NetworkAcls[0].NetworkAclId' --output text --region "$REGION"; }
nat()  { aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=$1" \
           "Name=state,Values=available" \
           --query 'NatGateways[0].NatGatewayId' --output text --region "$REGION"; }

log "라우팅 테이블"
by_name RT_SVC_PUB   "퍼블릭"   rt "${PREFIX}-rt-svc-pub"
by_name RT_SVC_APP_A "App-a"    rt "${PREFIX}-rt-svc-app-a"
by_name RT_SVC_APP_C "App-c"    rt "${PREFIX}-rt-svc-app-c"
by_name RT_SVC_DB    "DB"       rt "${PREFIX}-rt-svc-db"

log "보안 그룹"
by_name SG_ALB "alb" sg "${PREFIX}-sg-alb"
by_name SG_APP "app" sg "${PREFIX}-sg-app"
by_name SG_DB  "db"  sg "${PREFIX}-sg-db"

log "NAT 게이트웨이"
by_name NAT_SVC_A "서비스 VPC" nat "${PREFIX}-rnat-svc"

log "네트워크 ACL"
by_name NACL_SVC_APP "App 계층" nacl "${PREFIX}-nacl-svc-app"

log "NAT 모드"
MODE="$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Owner,Values=$PREFIX" "Name=state,Values=available" \
  --output json --region "$REGION" \
  | jq -r '[.NatGateways[] | .AvailabilityMode // "zonal"] | unique | .[0] // "unknown"')"
printf '  \033[32m확인\033[0m  %-16s %s\n' "NAT_MODE_USED" "$MODE"
[ "$WRITE" = "1" ] && save_state NAT_MODE_USED "$MODE"

echo
if [ "$MISSING" -gt 0 ]; then
  warn "$MISSING 개를 찾지 못했습니다."
  log  "  이름이 규칙과 다를 수 있습니다. 콘솔에서 Name 태그를 확인하십시오."
  log  "  기대하는 이름:"
  log  "    라우팅  ${PREFIX}-rt-svc-pub / -app-a / -app-c / -db"
  log  "    보안그룹 ${PREFIX}-sg-alb / -sg-app / -sg-db"
  log  "    NAT     ${PREFIX}-rnat-svc"
  log  "    NACL    ${PREFIX}-nacl-svc-app"
fi

if [ "$WRITE" = "1" ]; then
  ok "state 파일에 기록했습니다: $STATE_FILE"
  log "  이제 실행하십시오:  bash lab03-network/verify.sh"
else
  echo
  log "확인만 했습니다. 기록하려면:"
  log "  bash lab03-network/adopt-lab03.sh --write"
fi
