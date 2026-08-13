#!/usr/bin/env bash
# ============================================================
# state-sync.sh — state 파일을 S3에 백업/복원한다.
#
# 라이브러리로 쓰기:   . 00-common/state-sync.sh
# 명령으로 쓰기:       bash state-sync.sh push|pull|status|history|restore <VersionId>|init
#
# 버킷:  ${STATE_BUCKET:-${PREFIX}-state-${ACCOUNT_ID}}
# 키   :  capstone-state/${PREFIX}/state.env
#
# 랩 리소스와 수명 주기가 다르므로 teardown-all.sh는 이 버킷을 건드리지 않는다.
# ============================================================

state_bucket_name() {
  # guard를 거치지 않고 호출될 수 있으므로 ACCOUNT_ID를 지연 해석한다
  local acct="${ACCOUNT_ID:-}"
  if [ -z "$acct" ]; then
    acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    [ -n "$acct" ] && [ "$acct" != "None" ] && export ACCOUNT_ID="$acct"
  fi
  if [ -z "${STATE_BUCKET:-}" ] && [ -z "$acct" ]; then
    err "계정 ID를 확인할 수 없습니다. 자격 증명을 점검하거나 STATE_BUCKET을 직접 지정하세요."
    return 1
  fi
  printf '%s' "${STATE_BUCKET:-${PREFIX}-state-${acct}}"
}
state_s3_key()  { printf 'capstone-state/%s/state.env' "$PREFIX"; }
state_s3_uri()  { printf 's3://%s/%s' "$(state_bucket_name)" "$(state_s3_key)"; }

# ------------------------------------------------------------
# 버킷 준비 — 버전 관리 + 암호화 + 퍼블릭 차단. 멱등.
# ------------------------------------------------------------
state_bucket_ensure() {
  local b; b="$(state_bucket_name)"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    skip "state 버킷 $b"
  else
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$b" >/dev/null
    else
      aws s3api create-bucket --bucket "$b" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    ok "state 버킷 생성: $b"
  fi

  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
  # 버전 관리가 핵심 — 랩별 스냅샷으로 되돌릴 수 있게 한다
  aws s3api put-bucket-versioning --bucket "$b" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$b" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
  aws s3api put-bucket-tagging --bucket "$b" --tagging \
    "TagSet=[{Key=Project,Value=capstone},{Key=Purpose,Value=state},{Key=Owner,Value=$PREFIX}]" >/dev/null
  # 과거 버전이 무한히 쌓이지 않도록 정리
  aws s3api put-bucket-lifecycle-configuration --bucket "$b" --lifecycle-configuration \
    '{"Rules":[{"ID":"prune-old-state","Status":"Enabled","Filter":{"Prefix":"capstone-state/"},
      "NoncurrentVersionExpiration":{"NoncurrentDays":180,"NewerNoncurrentVersions":50}}]}' >/dev/null 2>&1 || true
  ok "state 버킷 준비 완료 (버전 관리·암호화·퍼블릭 차단)"
}

# ------------------------------------------------------------
# push — 로컬 → S3.  state_push "lab05 완료" 처럼 사유를 남길 수 있다.
# ------------------------------------------------------------
state_push() {
  local note="${1:-manual}" b; b="$(state_bucket_name)"
  [ -f "$STATE_FILE" ] || { warn "state 파일이 없습니다: $STATE_FILE"; return 1; }
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || state_bucket_ensure

  # S3 메타데이터 값은 US-ASCII만 허용한다. 한글·공백을 안전하게 치환한다.
  local note_ascii
  note_ascii="$(printf '%s' "$note" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | tr -s '_' | sed 's/^_//;s/_$//' | cut -c1-64)"
  [ -n "$note_ascii" ] || note_ascii="manual"

  local ver errout
  errout="$(mktemp)"
  ver="$(aws s3api put-object --bucket "$b" --key "$(state_s3_key)" \
      --body "$STATE_FILE" --content-type text/plain \
      --metadata "note=${note_ascii},host=${HOSTNAME:-unknown},at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --query VersionId --output text 2>"$errout")" \
    || { err "업로드 실패"; sed 's/^/      /' "$errout" >&2; rm -f "$errout"; return 1; }
  rm -f "$errout"
  ok "state 백업 완료 → $(state_s3_uri)"
  log "  버전 $ver  ($note)"
  return 0
}

# ------------------------------------------------------------
# pull — S3 → 로컬. 기존 파일은 .bak 으로 보존.
# ------------------------------------------------------------
state_pull() {
  local ver="${1:-}" b; b="$(state_bucket_name)"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || { warn "state 버킷이 없습니다: $b"; return 1; }

  local tmp; tmp="$(mktemp)"
  if [ -n "$ver" ]; then
    aws s3api get-object --bucket "$b" --key "$(state_s3_key)" --version-id "$ver" "$tmp" >/dev/null 2>&1 \
      || { err "버전 $ver 을 가져오지 못했습니다"; rm -f "$tmp"; return 1; }
  else
    aws s3api get-object --bucket "$b" --key "$(state_s3_key)" "$tmp" >/dev/null 2>&1 \
      || { warn "원격에 state가 없습니다 (최초 실행이면 정상)"; rm -f "$tmp"; return 1; }
  fi

  if [ -s "$STATE_FILE" ] && ! diff -q "$STATE_FILE" "$tmp" >/dev/null 2>&1; then
    cp "$STATE_FILE" "${STATE_FILE}.bak"
    warn "로컬 state가 원격과 달라 ${STATE_FILE}.bak 으로 보존했습니다"
  fi
  mv "$tmp" "$STATE_FILE"
  load_state
  ok "state 복원 완료 ← $(state_s3_uri)${ver:+ (버전 $ver)}"
  return 0
}

# ------------------------------------------------------------
# status — 로컬과 원격 비교
# ------------------------------------------------------------
state_status() {
  local b; b="$(state_bucket_name)"
  printf '  로컬 : %s' "$STATE_FILE"
  if [ -f "$STATE_FILE" ]; then
    printf '  (%s개 키, %s)\n' "$(grep -c '^export ' "$STATE_FILE" 2>/dev/null || echo 0)" \
      "$(date -r "$STATE_FILE" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')"
  else
    printf '  (없음)\n'
  fi

  printf '  원격 : %s' "$(state_s3_uri)"
  local meta
  meta="$(aws s3api head-object --bucket "$b" --key "$(state_s3_key)" --output json 2>/dev/null || true)"
  if [ -z "$meta" ]; then printf '  (없음)\n'; return 0; fi
  printf '  (%s, 버전 %s)\n' \
    "$(printf '%s' "$meta" | jq -r '.LastModified')" \
    "$(printf '%s' "$meta" | jq -r '.VersionId')"

  local tmp; tmp="$(mktemp)"
  if aws s3api get-object --bucket "$b" --key "$(state_s3_key)" "$tmp" >/dev/null 2>&1; then
    if [ -f "$STATE_FILE" ] && diff -q "$STATE_FILE" "$tmp" >/dev/null 2>&1; then
      ok "  로컬과 원격이 동일합니다"
    else
      warn "  로컬과 원격이 다릅니다 — 차이:"
      diff "$tmp" "${STATE_FILE:-/dev/null}" 2>/dev/null | sed 's/^/      /' | head -20 || true
      log "      < 원격 / > 로컬"
    fi
  fi
  rm -f "$tmp"
}

# ------------------------------------------------------------
# history — 버전 목록 (랩별 스냅샷 확인용)
# ------------------------------------------------------------
state_history() {
  local b; b="$(state_bucket_name)"
  local vs
  vs="$(aws s3api list-object-versions --bucket "$b" --prefix "$(state_s3_key)" --output json 2>/dev/null || true)"
  [ -n "$vs" ] || { warn "이력이 없습니다"; return 1; }
  printf '  %-34s %-22s %s\n' "VersionId" "LastModified" "note"
  printf '  %s\n' "$(printf '%.0s-' {1..78})"
  printf '%s' "$vs" | jq -r '.Versions // [] | sort_by(.LastModified) | reverse | .[] | [.VersionId,.LastModified] | @tsv' \
  | while IFS=$'\t' read -r v d; do
      local n
      n="$(aws s3api head-object --bucket "$b" --key "$(state_s3_key)" --version-id "$v" \
            --query 'Metadata.note' --output text 2>/dev/null || echo '-')"
      printf '  %-34s %-22s %s\n' "$v" "$d" "$n"
    done
}

# ------------------------------------------------------------
# CLI 진입점 — 이 파일을 직접 실행했을 때만 동작
# ------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap.sh"
  guard
  case "${1:-status}" in
    init)    state_bucket_ensure ;;
    push)    state_push "${2:-manual}" ;;
    pull)    state_pull "${2:-}" ;;
    status)  banner "state 동기화 상태"; state_status ;;
    history) banner "state 버전 이력"; state_history ;;
    restore)
      [ -n "${2:-}" ] || die "사용법: state-sync.sh restore <VersionId>   (history로 확인)"
      state_pull "$2" ;;
    *) cat << USAGE
사용법: bash state-sync.sh <명령>

  init              state 버킷 생성 (버전 관리·암호화·퍼블릭 차단)
  push [사유]       로컬 state를 S3에 백업
  pull              S3의 최신 state를 로컬로 복원
  status            로컬과 원격 비교
  history           버전 이력 조회
  restore <ver>     특정 버전으로 되돌리기

환경 변수:
  PREFIX            학생/과정 접두사 (기본 cap)
  STATE_BUCKET      버킷 이름 직접 지정 (기본 \${PREFIX}-state-\${ACCOUNT_ID})
USAGE
      exit 1 ;;
  esac
fi
