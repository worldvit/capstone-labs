#!/usr/bin/env bash
# ============================================================
# bootstrap.sh — 각 랩 스크립트의 첫 3줄을 이 한 줄로 대체한다.
#   source "$(dirname "$0")/../00-common/bootstrap.sh"
# env → lib → guard 로드 + state 복원 + 엄격 모드 설정까지 한 번에 처리.
# ============================================================
# 대화형 셸에 source 되면 엄격 모드를 켜지 않는다.
# set -e / exit 가 로그인 셸을 종료시켜 세션이 끊기는 사고를 막는다.
case $- in
  *i*) export CAPSTONE_INTERACTIVE=1 ;;
  *)   set -euo pipefail ;;
esac

_BS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$_BS_DIR/env.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/lib.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/guard.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/state-sync.sh"

load_state

# ACCOUNT_ID 확보 — verify 계열은 guard를 거치지 않으므로 여기서 채운다.
# 실패해도 진행한다(가드가 있는 스크립트는 guard가 다시 검사한다).
if [ -z "${ACCOUNT_ID:-}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [ "${ACCOUNT_ID:-}" = "None" ] && ACCOUNT_ID=""
  export ACCOUNT_ID
fi
