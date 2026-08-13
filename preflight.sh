#!/usr/bin/env bash
# ============================================================
# preflight.sh — 실습 시작 전 환경 점검
#
#   bash preflight.sh          ← 반드시 'bash'로 실행. source 하지 말 것.
#
# source 로 부르면 실패 시 로그인 셸이 끊길 수 있어 이 스크립트가 막는다.
# ============================================================

# source 로 불렸는지 검사 (bash 전용)
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  printf '\033[31m[✘]\033[0m 이 스크립트는 source 하지 마십시오.\n' >&2
  printf '     올바른 사용:  bash preflight.sh\n' >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/00-common/bootstrap.sh"

banner "사전 점검"

FAIL=0
row() { # row "항목" "상태" "설명"
  local mark
  case "$2" in
    ok)   mark="${C_G}✔${C_0}" ;;
    warn) mark="${C_Y}!${C_0}" ;;
    *)    mark="${C_R}✘${C_0}"; FAIL=$((FAIL+1)) ;;
  esac
  printf '  [%b] %-22s %s\n' "$mark" "$1" "$3"
}

# ---------- 1. 필수 도구 ----------
for c in aws jq curl zip; do
  if command -v "$c" >/dev/null 2>&1; then row "$c" ok "$(command -v "$c")"
  else row "$c" fail "설치 필요"; fi
done
v="$(aws --version 2>&1 | awk '{print $1}')"
case "$v" in aws-cli/2.*) row "AWS CLI 버전" ok "$v" ;; *) row "AWS CLI 버전" warn "$v (v2 권장)" ;; esac

# ---------- 2. 실행 환경 ----------
if [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ]; then
  row "실행 환경" ok "AWS CloudShell (앰비언트 자격 증명)"
else
  row "실행 환경" ok "${AWS_EXECUTION_ENV:-일반 셸} / 프로파일 ${AWS_PROFILE:-<미설정>}"
fi

# ---------- 3. 자격 증명과 계정 ----------
caller="$(aws sts get-caller-identity --output json 2>/dev/null || true)"
if [ -z "$caller" ]; then
  row "자격 증명" fail "sts get-caller-identity 실패 — 재로그인 필요"
else
  acct="$(printf '%s' "$caller" | jq -r .Account)"
  arn="$(printf '%s' "$caller" | jq -r .Arn)"
  row "자격 증명" ok "$arn"
  matched=0
  IFS=',' read -ra want <<< "$EXPECTED_ACCOUNT_IDS"
  for w in "${want[@]}"; do [ "$acct" = "$(echo "$w" | tr -d ' ')" ] && matched=1; done || true
  if [ "$matched" = 1 ]; then row "계정 일치" ok "$acct"
  else row "계정 일치" fail "현재 $acct / 허용 $EXPECTED_ACCOUNT_IDS → env.sh 수정 필요"; fi
fi

# ---------- 4. 리전과 AZ ----------
azs="$(aws ec2 describe-availability-zones --region "$REGION" \
        --query 'AvailabilityZones[?State==`available`].ZoneName' --output text 2>/dev/null | tr '\t' ' ')"
if [ -z "$azs" ]; then
  row "리전 $REGION" fail "AZ 조회 실패"
else
  row "리전 $REGION" ok "AZ: $azs"
  for z in "$AZ_A" "$AZ_C"; do
    case " $azs " in *" $z "*) row "가용 영역 $z" ok "사용 가능" ;;
                     *) row "가용 영역 $z" fail "이 리전에 없음" ;; esac
  done
fi

# ---------- 5. 명명 규칙 미리보기 ----------
printf '\n  %s명명 미리보기%s\n' "$C_B" "$C_0"
printf '    접두사    : %s\n' "$PREFIX"
printf '    서비스 VPC: %-16s %s\n' "$N_VPC_SVC" "$VPC_SVC_CIDR"
printf '    관리 VPC  : %-16s %s\n' "$N_VPC_MGMT" "$VPC_MGMT_CIDR"
printf '    state     : %s\n' "$STATE_FILE"
printf '    S3 백업   : %s\n' "$([ "$STATE_SYNC" = 1 ] && echo "켜짐" || echo "꺼짐 (STATE_SYNC=1 로 활성화)")"

# ---------- 6. 기존 리소스 충돌 확인 ----------
printf '\n  %s기존 리소스 확인%s\n' "$C_B" "$C_0"
n="$(aws ec2 describe-vpcs --filters "Name=tag:Owner,Values=$PREFIX" \
      --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
if [ "$n" = "0" ]; then row "기존 캡스톤 VPC" ok "없음 (깨끗한 시작)"
else row "기존 캡스톤 VPC" warn "$n개 존재 — 이어서 진행하거나 teardown-all.sh 먼저 실행"; fi

if [ -s "$STATE_FILE" ]; then
  row "state 파일" warn "$(grep -c '^export ' "$STATE_FILE")개 키 보유 — 이어하기 가능"
else
  row "state 파일" ok "비어 있음"
fi

# ---------- 7. 비용 경고 ----------
printf '\n  %s비용 안내%s\n' "$C_Y" "$C_0"
printf '    Lab 3부터 NAT 게이트웨이 4개가 시간당 과금됩니다.\n'
printf '    Lab 8 Aurora 2노드, Lab 10 ALB도 상시 과금 대상입니다.\n'
printf '    사용하지 않을 때는 bash teardown-all.sh 로 정리하십시오.\n'

# ---------- 결과 ----------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  ok "사전 점검 통과 — 다음 단계로 진행하십시오"
  printf '\n    bash 00-common/state-sync.sh init     # state 백업 버킷 생성\n'
  printf '    STATE_SYNC=1 bash build-all.sh 1      # Lab 1 실행\n\n'
else
  err "미충족 항목 ${FAIL}개 — 위 표를 확인하십시오"
  exit 1
fi
