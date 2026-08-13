#!/usr/bin/env bash
# ============================================================
# guard.sh — 오폭 방지. 모든 build/teardown 스크립트가 최초에 호출한다.
# 운영 계정에서 실습이 돌아가는 동안 이 가드가 유일한 방어선이다.
# ============================================================

guard() {
  require_tools

  # 1. 자격 증명 유효성 + 계정 확인
  local caller acct arn
  local pname="${AWS_PROFILE:-<앰비언트 자격 증명>}"
  caller="$(aws sts get-caller-identity --output json 2>/dev/null)" \
    || { die "자격 증명이 없거나 만료되었습니다. (프로파일: $pname) 확인 후 재로그인하세요."; return 1; }
  acct="$(printf '%s' "$caller" | jq -r '.Account')"
  arn="$(printf '%s' "$caller" | jq -r '.Arn')"
  export ACCOUNT_ID="$acct"

  local matched=0 want
  IFS=',' read -ra want <<< "$EXPECTED_ACCOUNT_IDS"
  for w in "${want[@]}"; do
    [ "$acct" = "$(echo "$w" | tr -d ' ')" ] && matched=1 || true
  done
  if [ "$matched" -ne 1 ]; then
    err "계정 불일치 — 실행을 중단합니다."
    err "  현재 계정 : $acct"
    err "  허용 계정 : $EXPECTED_ACCOUNT_IDS"
    err "  프로파일  : $pname"
    die "env.sh의 EXPECTED_ACCOUNT_IDS를 확인하거나 올바른 프로파일을 지정하세요." || return 1
  fi

  # 2. 리전 확인
  local cur; cur="$(aws configure get region 2>/dev/null || true)"
  if [ -n "$cur" ] && [ "$cur" != "$REGION" ]; then
    warn "프로파일 기본 리전($cur)과 REGION($REGION)이 다릅니다. REGION 값을 사용합니다."
  fi

  # 3. AZ 실재 여부 확인 (리전마다 c가 없는 경우가 있음)
  local azs
  azs="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[?State==`available`].ZoneName' --output text | tr '\t' ' ')"
  for z in "$AZ_A" "$AZ_C"; do
    case " $azs " in
      *" $z "*) : ;;
      *) die "가용 영역 $z 를 $REGION 에서 사용할 수 없습니다. 사용 가능: $azs" || return 1 ;;
    esac
  done

  # 4. 프로파일 명시 여부 경고
  if [ "${AWS_PROFILE:-}" = "default" ]; then
    warn "기본 프로파일로 실행 중입니다. 전용 프로파일 사용을 권장합니다."
  fi

  ok "가드 통과 — 계정 $acct / 리전 $REGION / 접두사 $PREFIX"
  log "  자격 증명: $pname"
  log "  실행 주체: $arn"
  log "  state    : $STATE_FILE"
}
