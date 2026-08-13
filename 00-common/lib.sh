#!/usr/bin/env bash
# ============================================================
# lib.sh — 공통 함수. env.sh 다음에 source 한다.
# ============================================================

# ---------- 출력 ----------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi

log()  { printf '%s[·]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[✔]%s %s\n' "$C_G" "$C_0" "$*"; }
skip() { printf '%s[=]%s %s (이미 존재)\n' "$C_Y" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[✘]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
# 대화형 셸에서는 exit 대신 return 1 — 로그인 셸이 끊기지 않게 한다.
# 호출부는  die "..." || return 1  형태로 쓴다.
die()  { err "$*"; if [ -n "${CAPSTONE_INTERACTIVE:-}" ]; then return 1; fi; exit 1; }

banner() {
  printf '\n%s================================================================%s\n' "$C_B" "$C_0"
  printf '%s %s%s\n' "$C_B" "$*" "$C_0"
  printf '%s================================================================%s\n' "$C_B" "$C_0"
}

# ---------- 사전 요구 ----------
need() { command -v "$1" >/dev/null 2>&1 || die "필수 명령이 없습니다: $1"; }

require_tools() {
  need aws
  need jq
  local v; v="$(aws --version 2>&1)"
  case "$v" in
    aws-cli/2.*) : ;;
    *) warn "AWS CLI v2 권장. 현재: $v" ;;
  esac
}

# ---------- 상태 파일 ----------
# save_state KEY VALUE  — 같은 키가 있으면 교체, 없으면 추가
save_state() {
  local k="$1" v="$2"
  [ -n "$v" ] && [ "$v" != "None" ] || { warn "save_state: $k 값이 비어 있어 저장하지 않음"; return 0; }
  touch "$STATE_FILE"
  if grep -q "^export ${k}=" "$STATE_FILE" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "^export ${k}=" "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
  printf 'export %s=%q\n' "$k" "$v" >> "$STATE_FILE"
  export "$k=$v"
}

drop_state() {
  local k="$1"
  [ -f "$STATE_FILE" ] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v "^export ${k}=" "$STATE_FILE" > "$tmp" || true
  mv "$tmp" "$STATE_FILE"
  unset "$k" 2>/dev/null || true
}

load_state() {
  # shellcheck disable=SC1090
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
  return 0
}

# need_state KEY... — 없으면 어느 랩을 먼저 실행해야 하는지 알려주고 중단
need_state() {
  local missing=()
  for k in "$@"; do
    [ -n "${!k:-}" ] || missing+=("$k")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    err "선행 랩의 산출물이 없습니다: ${missing[*]}"
    err "state 파일: $STATE_FILE"
    die "먼저 실행하세요:  bash build-all.sh <이번랩번호-1>" || return 1
  fi
}

# ---------- 태그 ----------
# tagspec RESOURCE_TYPE NAME LAB  → --tag-specifications 인자값 생성
tagspec() {
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=capstone},{Key=Lab,Value=%s},{Key=Owner,Value=%s}]' \
    "$1" "$2" "$3" "$PREFIX"
}

# tag_resource ID NAME LAB — 생성 후 태깅 (tag-specifications 미지원 리소스용)
tag_resource() {
  aws ec2 create-tags --resources "$1" --tags \
    "Key=Name,Value=$2" "Key=Project,Value=capstone" "Key=Lab,Value=$3" "Key=Owner,Value=$PREFIX"
}

# ---------- 조회 (없으면 빈 문자열) ----------
_q() { # _q <aws args...>  → None/공백을 빈 문자열로 정규화
  local out
  out="$("$@" 2>/dev/null)" || return 0
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}

vpc_id_by_name()    { _q aws ec2 describe-vpcs    --filters "Name=tag:Name,Values=$1" --query 'Vpcs[0].VpcId' --output text; }
subnet_id_by_name() { _q aws ec2 describe-subnets --filters "Name=tag:Name,Values=$1" --query 'Subnets[0].SubnetId' --output text; }
igw_id_by_name()    { _q aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$1" --query 'InternetGateways[0].InternetGatewayId' --output text; }
rt_id_by_name()     { _q aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$1" --query 'RouteTables[0].RouteTableId' --output text; }
natgw_id_by_name()  { _q aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=$1" "Name=state,Values=pending,available" --query 'NatGateways[0].NatGatewayId' --output text; }
sg_id_by_name()     { _q aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId' --output text; }
eip_alloc_by_name() { _q aws ec2 describe-addresses --filters "Name=tag:Name,Values=$1" --query 'Addresses[0].AllocationId' --output text; }
instance_id_by_name() { _q aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text; }
tgw_id_by_name()    { _q aws ec2 describe-transit-gateways --filters "Name=tag:Name,Values=$1" "Name=state,Values=pending,available,modifying" --query 'TransitGateways[0].TransitGatewayId' --output text; }
tgw_attach_by_vpc() { _q aws ec2 describe-transit-gateway-attachments --filters "Name=resource-id,Values=$1" "Name=state,Values=pending,available,initiating,initiatingRequest,modifying" --query 'TransitGatewayAttachments[0].TransitGatewayAttachmentId' --output text; }
vpce_id_by_name()   { _q aws ec2 describe-vpc-endpoints --filters "Name=tag:Name,Values=$1" --query 'VpcEndpoints[0].VpcEndpointId' --output text; }

# AMI를 SSM 퍼블릭 파라미터로 조회 (ID 하드코딩 금지 원칙)
latest_ami() {
  local id
  id="$(_q aws ssm get-parameter --name "$AMI_SSM_PARAM" --query 'Parameter.Value' --output text)"
  [ -n "$id" ] || die "AMI 조회 실패: $AMI_SSM_PARAM"
  printf '%s' "$id"
}

# ---------- 대기 ----------
# wait_until "설명" 최대초 간격초 <판정명령...>   판정명령이 exit 0이면 통과
wait_until() {
  local desc="$1" max="$2" iv="$3"; shift 3
  local waited=0
  printf '%s[·]%s %s 대기' "$C_B" "$C_0" "$desc"
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$max" ]; then
      printf '\n'; err "$desc 시간 초과 (${max}초)"; return 1
    fi
    printf '.'
    sleep "$iv"; waited=$((waited + iv))
  done
  printf ' 완료 (%s초)\n' "$waited"
  return 0
}

retry() { # retry 횟수 간격 <명령...>
  local n="$1" iv="$2"; shift 2
  local i=1
  until "$@"; do
    [ "$i" -ge "$n" ] && return 1
    sleep "$iv"; i=$((i + 1))
  done
  return 0
}

# ---------- verify.sh 전용 ----------
CHECK_PASS=0; CHECK_FAIL=0; CHECK_LAB=""

check_begin() { CHECK_LAB="$1"; CHECK_PASS=0; CHECK_FAIL=0
  printf '\n%s[%s]%s\n' "$C_B" "$CHECK_LAB" "$C_0"; }

# check "설명" <판정명령...>
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$desc"; CHECK_PASS=$((CHECK_PASS + 1))
  else
    printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$desc"; CHECK_FAIL=$((CHECK_FAIL + 1))
  fi
}

# check_eq "설명" 기대값 <값을출력하는명령...>
check_eq() {
  local desc="$1" want="$2"; shift 2
  local got; got="$("$@" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$desc"; CHECK_PASS=$((CHECK_PASS + 1))
  else
    printf '  %sFAIL%s  %s (기대 %s / 실제 %s)\n' "$C_R" "$C_0" "$desc" "$want" "${got:-없음}"
    CHECK_FAIL=$((CHECK_FAIL + 1))
  fi
}

check_summary() {
  local total=$((CHECK_PASS + CHECK_FAIL))
  printf '  ---\n'
  if [ "$CHECK_FAIL" -eq 0 ]; then
    printf '  결과: %s%d/%d%s  통과\n' "$C_G" "$CHECK_PASS" "$total" "$C_0"
    return 0
  else
    printf '  결과: %s%d/%d%s  →  FAIL 항목을 다시 구성하십시오\n' "$C_R" "$CHECK_PASS" "$total" "$C_0"
    return 1
  fi
}

# ---------- 삭제 보조 ----------
confirm_destroy() {
  [ "${FORCE:-0}" = "1" ] && return 0
  printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$1"
  read -r -p "    삭제하려면 정확히 'delete' 입력: " a
  [ "$a" = "delete" ] || die "취소했습니다."
}

# 실패해도 계속 진행 (teardown 전용)
soft() { "$@" >/dev/null 2>&1 || true; }
