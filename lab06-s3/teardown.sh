#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 6 teardown"
confirm_destroy "S3 버킷 2개를 비웁니다. (버킷 자체는 기본적으로 유지 — 이름 재사용 대기 회피)"

empty_bucket() {
  local b="$1"
  [ -n "$b" ] || return 0
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || { log "버킷 없음: $b"; return 0; }

  soft aws s3 rm "s3://$b" --recursive

  # 버전 관리가 켜진 버킷은 버전과 삭제 마커가 남는다. 1000개씩 나눠 지운다.
  # (delete-objects의 1회 한도가 1000개)
  local total=0 pass=0
  while [ "$pass" -lt 50 ]; do
    local batch n tmp
    tmp="$(mktemp)"
    aws s3api list-object-versions --bucket "$b" --max-items 1000 --output json 2>/dev/null \
      | jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId}))}' > "$tmp" 2>/dev/null || true
    n="$(jq -r '.Objects | length' "$tmp" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] || { rm -f "$tmp"; break; }
    if aws s3api delete-objects --bucket "$b" --delete "file://$tmp" >/dev/null 2>&1; then
      total=$((total + n))
    else
      warn "  버전 삭제 실패 — 남은 객체 ${n}개"; rm -f "$tmp"; break
    fi
    rm -f "$tmp"
    pass=$((pass + 1))
  done

  local left
  left="$(aws s3api list-object-versions --bucket "$b" \
          --query 'length(Versions[] || `[]`)' --output text 2>/dev/null || echo 0)"
  if [ "${left:-0}" = "0" ] || [ "$left" = "None" ]; then
    ok "버킷 비움: $b (버전 ${total}개 삭제)"
  else
    warn "버킷 $b 에 객체가 남아 있습니다: $left"
  fi
}
empty_bucket "${BUCKET_WEB:-}"
empty_bucket "${BUCKET_LOGS:-}"

if [ "${DELETE_BUCKETS:-0}" = "1" ]; then
  warn "버킷을 삭제합니다. 같은 이름은 최대 48~72시간 재사용할 수 없습니다."
  soft aws s3api delete-bucket --bucket "${BUCKET_WEB:-}"
  soft aws s3api delete-bucket --bucket "${BUCKET_LOGS:-}"
  drop_state BUCKET_WEB; drop_state BUCKET_LOGS
else
  log "버킷 유지. 완전 삭제하려면 DELETE_BUCKETS=1 로 재실행하세요."
fi
drop_state LAB06_DONE
ok "Lab 6 teardown 완료"
