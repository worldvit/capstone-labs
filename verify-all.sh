#!/usr/bin/env bash
# verify-all.sh [끝랩번호]  — 전체 랩 상태 진단표
source "$(dirname "$0")/00-common/bootstrap.sh"

guard

# 위치 번호는 1부터. lab08b-3tier(3-Tier 기본)가 9번이며 이후가 한 칸씩 밀린다.
# 랩 이름을 직접 넘겨도 된다:  bash build-all.sh lab08b-3tier
LABS=(dummy lab01-iam lab02-vpc lab03-network lab04-ec2 lab05-endpoint-tgw lab06-s3 lab07-efs \
      lab08-aurora lab08b-3tier lab09-observability lab10-alb-asg lab11-cloudfront-waf \
      lab12-serverless lab13-backup)

# 번호 또는 랩 이름을 위치 번호로 바꾼다.
resolve_lab() {
  local v="$1" i
  case "$v" in
    ''|*[!0-9]*)
      for i in "${!LABS[@]}"; do [ "${LABS[$i]}" = "$v" ] && { printf '%s' "$i"; return 0; }; done
      for i in "${!LABS[@]}"; do case "${LABS[$i]}" in "$v"*) printf '%s' "$i"; return 0 ;; esac; done
      return 1 ;;
    *) printf '%s' "$v" ;;
  esac
}

list_labs() {
  printf '  %-4s %s\n' "번호" "랩"
  local i
  for i in $(seq 1 $(( ${#LABS[@]} - 1 ))); do printf '  %-4s %s\n' "$i" "${LABS[$i]}"; done
}

if [ "${1:-}" = "--list" ]; then banner "랩 목록"; list_labs; exit 0; fi
TO="$(resolve_lab "${1:-14}")" || die "알 수 없는 랩: ${1:-}"

banner "전체 진단  (접두사 $PREFIX / 계정 $ACCOUNT_ID / 리전 $REGION)"
TOTAL_FAIL=0; SUMMARY=""
for i in $(seq 1 "$TO"); do
  d="${LABS[$i]}"
  out="$(bash "$ROOT_DIR/$d/verify.sh" 2>&1)" && rc=0 || rc=1
  printf '%s\n' "$out"
  line="$(printf '%s' "$out" | grep -o '결과: [0-9]*/[0-9]*' | tail -1)"
  if [ "$rc" -eq 0 ]; then
    SUMMARY="${SUMMARY}\n  Lab $(printf '%2d' $i)  ${C_G}통과${C_0}   ${line}"
  else
    SUMMARY="${SUMMARY}\n  Lab $(printf '%2d' $i)  ${C_R}미충족${C_0} ${line}"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
done

banner "요약"
printf '%b\n\n' "$SUMMARY"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  ok "Lab 1~$TO 전체 통과"
else
  err "미충족 랩 ${TOTAL_FAIL}개"
  if [ -f "$ROOT_DIR/build-all.sh" ]; then
    log "  복구: bash lab<번호>-*/repair.sh"
  else
    log "  위 FAIL 항목을 실습 문서에 따라 다시 구성하십시오."
  fi
  exit 1
fi
