#!/usr/bin/env bash
# ============================================================
# adopt-lab04.sh — 콘솔로 만든 Lab 4 리소스를 state 파일에 등록한다.
#
# 사용법:
#   cd ~/capstone-labs
#   bash lab04-ec2/adopt-lab04.sh          # 확인만
#   bash lab04-ec2/adopt-lab04.sh --write  # state 파일에 기록
#
# verify.sh 는 인스턴스를 ID로 조회한다. build.sh 로 만들면 자동으로
# 기록되지만, 콘솔로 만들면 비어 있어 검사가 대부분 실패한다.
# 이 스크립트는 Name 태그로 인스턴스를 찾아 그 빈칸을 채운다.
#
# Lab 3 의 NAT 정보도 필요하므로 없으면 함께 채운다.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source 00-common/bootstrap.sh

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

banner "Lab 4 콘솔 리소스 등록"

MISSING=0

# ec2_id <Name태그>  → 실행 중인 인스턴스 ID
ec2_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$1" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[0].InstanceId | [0]' --output text 2>/dev/null
}

adopt() {  # adopt <키> <Name태그>
  local key="$1" name="$2" id
  id="$(ec2_id "$name" | tr -d '\r')"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    printf '  \033[31m없음\033[0m  %-16s %s\n' "$key" "$name"
    MISSING=$((MISSING+1))
    return 1
  fi
  printf '  \033[32m찾음\033[0m  %-16s %s\n' "$key" "$id"
  [ "$WRITE" = "1" ] && save_state "$key" "$id"
  return 0
}

log "EC2 인스턴스"
adopt BASTION_ID "${PREFIX}-bastion"
adopt APP_A_ID   "${PREFIX}-app-a"
adopt APP_C_ID   "${PREFIX}-app-c"

# Bastion 퍼블릭 IP — 실습 4 이후 접속 안내에 쓰인다
BIP="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${PREFIX}-bastion" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].PublicIpAddress | [0]' --output text 2>/dev/null | tr -d '\r')"
if [ -n "$BIP" ] && [ "$BIP" != "None" ]; then
  printf '  \033[32m찾음\033[0m  %-16s %s\n' "BASTION_IP" "$BIP"
  [ "$WRITE" = "1" ] && save_state BASTION_IP "$BIP"
else
  printf '  \033[31m없음\033[0m  %-16s %s\n' "BASTION_IP" "퍼블릭 IP가 없습니다"
  MISSING=$((MISSING+1))
fi

log "AMI"
AMI="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${PREFIX}-app-a" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].ImageId | [0]' --output text 2>/dev/null | tr -d '\r')"
if [ -n "$AMI" ] && [ "$AMI" != "None" ]; then
  printf '  \033[32m찾음\033[0m  %-16s %s\n' "AMI_ID" "$AMI"
  [ "$WRITE" = "1" ] && save_state AMI_ID "$AMI"
else
  printf '  \033[31m없음\033[0m  %-16s %s\n' "AMI_ID" "app-a를 찾지 못했습니다"
  MISSING=$((MISSING+1))
fi

# ------------------------------------------------------------
# Lab 3 의 NAT 정보 — verify.sh 가 아웃바운드 경로 검사에 쓴다
# ------------------------------------------------------------
log "Lab 3 NAT 정보"
if [ -n "${NAT_SVC_A:-}" ]; then
  printf '  \033[32m확인\033[0m  %-16s %s (이미 기록됨)\n' "NAT_SVC_A" "$NAT_SVC_A"
else
  NAT="$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=tag:Name,Values=${PREFIX}-rnat-svc" "Name=state,Values=available" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null | tr -d '\r')"
  if [ -n "$NAT" ] && [ "$NAT" != "None" ]; then
    printf '  \033[32m찾음\033[0m  %-16s %s\n' "NAT_SVC_A" "$NAT"
    [ "$WRITE" = "1" ] && save_state NAT_SVC_A "$NAT"
  else
    printf '  \033[31m없음\033[0m  %-16s %s\n' "NAT_SVC_A" "${PREFIX}-rnat-svc"
    MISSING=$((MISSING+1))
  fi
fi

MODE="$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:Owner,Values=$PREFIX" "Name=state,Values=available" --output json 2>/dev/null \
  | jq -r '[.NatGateways[] | .AvailabilityMode // "zonal"] | unique | .[0] // "unknown"')"
printf '  \033[32m확인\033[0m  %-16s %s\n' "NAT_MODE_USED" "$MODE"
[ "$WRITE" = "1" ] && save_state NAT_MODE_USED "$MODE"

echo
if [ "$MISSING" -gt 0 ]; then
  warn "$MISSING 개를 찾지 못했습니다."
  log  "  이름이 규칙과 다르거나 인스턴스가 중지 상태일 수 있습니다."
  log  "  기대하는 이름:"
  log  "    EC2   ${PREFIX}-bastion / ${PREFIX}-app-a / ${PREFIX}-app-c"
  log  "    NAT   ${PREFIX}-rnat-svc"
  log  "  콘솔에서 Name 태그와 인스턴스 상태를 확인하십시오."
fi

if [ "$WRITE" = "1" ]; then
  ok "state 파일에 기록했습니다: $STATE_FILE"
  log "  이제 실행하십시오:  bash lab04-ec2/verify.sh"
else
  echo
  log "확인만 했습니다. 기록하려면:"
  log "  bash lab04-ec2/adopt-lab04.sh --write"
fi
