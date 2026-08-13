#!/usr/bin/env bash
# analyze.sh — 수집된 로그를 실제로 읽고 해석한다.
#
#   bash lab09-observability/analyze.sh            전체 실행
#   bash lab09-observability/analyze.sh 3          3번 항목만
#   bash lab09-observability/analyze.sh --list     항목 목록
#
# 관측성의 값어치는 수집이 아니라 해석에서 나온다.
# 각 항목은 "무엇을 묻는가 → 어떻게 묻는가 → 무엇을 읽어내는가" 순서로 구성했다.
# 이 스크립트는 실행 전용이다. source 하면 셸에 변수가 남고 전체가 실행된다.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  printf '[X] source 하지 마십시오.  올바른 사용:  bash %s\n' "${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

source "$(dirname "$0")/../00-common/bootstrap.sh"

# 분석 스크립트는 쿼리 하나가 실패해도 나머지 항목을 계속 보여줘야 한다.
set +e
set +o pipefail

MINUTES="${MINUTES:-60}"          # 분석 대상 기간(분)
START_MS=$(( ($(date +%s) - MINUTES * 60) * 1000 ))
END_MS=$(( $(date +%s) * 1000 ))

TITLES=(
  "dummy"
  "nginx 상태 코드 분포 — 서비스가 건강한가"
  "nginx 응답 시간 상위 — 어느 요청이 느린가"
  "요청이 두 App 서버에 고르게 분산되는가"
  "Tomcat 오류 로그 — 애플리케이션이 예외를 던지는가"
  "VPC Flow Logs 거부 트래픽 — 누가 무엇을 두드리는가"
  "3계층 통신 경로 — 설계대로 흐르는가"
  "CloudTrail — 누가 무엇을 바꿨는가"
  "지표 요약 — CPU·메모리·DB 연결"
)

usage() {
  banner "로그 분석 항목"
  local i
  for i in $(seq 1 $(( ${#TITLES[@]} - 1 ))); do printf '  %-3s %s\n' "$i" "${TITLES[$i]}"; done
  printf '\n  기간 조정: MINUTES=180 bash %s\n\n' "$0"
}
[ "${1:-}" = "--list" ] && { usage; exit 0; }

# ------------------------------------------------------------
# TSV 를 열 정렬해 출력한다. column(util-linux)이 없는 환경도 있어 awk 로 처리한다.
# ------------------------------------------------------------
tabalign() {
  awk -F'\t' '
    { for (i=1;i<=NF;i++) { c[NR,i]=$i; if (length($i)>w[i]) w[i]=length($i) }
      if (NF>maxf) maxf=NF; rows=NR }
    END {
      for (r=1;r<=rows;r++) {
        line="    "
        for (i=1;i<=maxf;i++) { line = line sprintf("%-*s  ", w[i], c[r,i]) }
        sub(/[ \t]+$/, "", line); print line
      }
    }'
}

# ------------------------------------------------------------
# Logs Insights 쿼리를 실행하고 결과를 표로 출력한다.
# ------------------------------------------------------------
insights() { # insights <로그그룹> <쿼리> [최대대기초]
  local lg="$1" q="$2" maxw="${3:-60}"
  local qid status waited=0

  local qerr
  qerr="$(mktemp)"
  qid="$(aws logs start-query --log-group-name "$lg" \
        --start-time "$START_MS" --end-time "$END_MS" \
        --query-string "$q" --query 'queryId' --output text 2>"$qerr")" \
    || { warn "쿼리 시작 실패 (로그 그룹: $lg)"
         sed 's/^/      /' "$qerr" >&2; rm -f "$qerr"; return 1; }
  rm -f "$qerr"

  while [ "$waited" -lt "$maxw" ]; do
    status="$(_q aws logs get-query-results --query-id "$qid" --query 'status' --output text)"
    case "$status" in
      Complete) break ;;
      Failed|Cancelled|Timeout) warn "쿼리 상태: $status"; return 1 ;;
    esac
    sleep 3; waited=$((waited + 3))
  done
  [ "$status" = "Complete" ] || { warn "쿼리 시간 초과"; return 1; }

  local json rows
  json="$(aws logs get-query-results --query-id "$qid" --output json 2>/dev/null)" || return 1
  rows="$(printf '%s' "$json" | jq -r '.results | length')"
  if [ "${rows:-0}" = "0" ]; then
    log "  (해당 기간에 데이터 없음 — MINUTES 값을 늘려 보십시오)"
    return 0
  fi

  # 필드 이름을 헤더로, 값을 행으로 출력한다(@ptr 은 내부 포인터라 제외).
  printf '%s' "$json" | jq -r '
    [.results[] | map(select(.field != "@ptr")) | map(.value)] as $rows
    | ([.results[0] | map(select(.field != "@ptr")) | .[].field] | @tsv), ($rows[] | @tsv)' \
  | tabalign
  return 0
}

# ------------------------------------------------------------
sec() { printf '\n%s┌ %s%s\n' "$C_B" "$1" "$C_0"; }
ask() { printf '%s│ 묻는 것:%s %s\n' "$C_Y" "$C_0" "$1"; }
read_it() { printf '%s└ 읽는 법:%s %s\n\n' "$C_G" "$C_0" "$1"; }

# ------------------------------------------------------------
a1() {
  sec "${TITLES[1]}"
  ask "정상 응답과 오류 응답의 비율. 502가 보이면 App 계층이 죽은 것이다."
  insights "$N_LOGGROUP_APP" '
fields @timestamp, @message
| filter @logStream like /nginx\/access/
| parse @message "* * * [*] \"* * *\" * *" as ip, ident, user, ts, method, path, proto, status, bytes
| stats count(*) as cnt by status
| sort cnt desc'
  read_it "2xx 만 있으면 정상. 5xx 가 있으면 App 계층, 4xx 가 많으면 잘못된 요청이나 스캔."
}

a2() {
  sec "${TITLES[2]}"
  ask "어떤 경로가 느리거나 응답이 큰가. 튜닝 대상을 찾는다."
  insights "$N_LOGGROUP_APP" '
fields @timestamp, @message
| filter @logStream like /nginx\/access/
| parse @message "* * * [*] \"* * *\" * *" as ip, ident, user, ts, method, path, proto, status, bytes
| stats count(*) as requests, avg(bytes) as avg_bytes, max(bytes) as max_bytes by path
| sort requests desc
| limit 10'
  read_it "평균 바이트가 큰 경로가 대역폭을 먹는다. Lab 11에서 CloudFront 캐싱 대상 후보."
}

a3() {
  sec "${TITLES[3]}"
  ask "nginx upstream 이 두 App 서버에 고르게 보내는가. 한쪽으로 쏠리면 장애 신호."
  insights "$N_LOGGROUP_APP" '
fields @timestamp
| filter @logStream like /tomcat/
| stats count(*) as log_lines by @logStream
| sort log_lines desc'
  read_it "두 인스턴스가 비슷해야 정상. 한쪽만 나오면 다른 쪽 Tomcat 이 죽었거나 upstream 에서 빠진 것."
  printf '    %s실측:%s 다음 명령으로 실제 분산을 확인하십시오.\n' "$C_B" "$C_0"
  printf '      for i in $(seq 1 10); do curl -s -H "Connection: close" http://%s/ \\\n' "${NGINX_IP:-<nginx-ip>}"
  printf '        | sed -n "s|.*APP_INSTANCE</th><td>\\([^<]*\\).*|\\1|p"; done | sort | uniq -c\n\n'
}

a4() {
  sec "${TITLES[4]}"
  ask "애플리케이션이 예외를 던지는가. DB 연결 실패가 여기 남는다."
  insights "$N_LOGGROUP_APP" '
fields @timestamp, @logStream, @message
| filter @logStream like /tomcat/
| filter @message like /(?i)(error|exception|severe|fail)/
| sort @timestamp desc
| limit 15'
  read_it "SQLException 이 보이면 DB 경로 문제. ClassNotFoundException 이면 JDBC 드라이버 누락."
}

a5() {
  sec "${TITLES[5]}"
  ask "보안 그룹이 실제로 무엇을 막았는가. 설계 의도가 지켜지는지 확인한다."
  insights "$N_LOGGROUP_FLOW" '
fields @timestamp, srcAddr, dstAddr, dstPort, protocol, action
| filter action = "REJECT"
| stats count(*) as rejects by dstPort, srcAddr
| sort rejects desc
| limit 15'
  read_it "22·3389 로의 외부 시도는 인터넷 스캔이다. 내부 IP 가 8080·5432 로 거부되면 SG 설정을 점검할 것."
}

a6() {
  sec "${TITLES[6]}"
  ask "3계층 트래픽이 설계대로 흐르는가. 허용된 흐름만 보여야 한다."
  insights "$N_LOGGROUP_FLOW" '
fields srcAddr, dstAddr, dstPort, action, bytes
| filter action = "ACCEPT" and (dstPort = 8080 or dstPort = 5432 or dstPort = 80)
| stats count(*) as flows, sum(bytes) as total_bytes by dstPort, srcAddr, dstAddr
| sort flows desc
| limit 20'
  read_it "80 은 인터넷→nginx, 8080 은 nginx→Tomcat, 5432 는 Tomcat→DB 여야 한다.
             다른 조합이 보이면 설계에 없는 경로가 열린 것이다."
}

a7() {
  sec "${TITLES[7]}"
  ask "누가 어떤 API 를 호출해 인프라를 바꿨는가. 사고 조사의 출발점."
  local since
  since="$(date -u -d "-${MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  aws cloudtrail lookup-events --start-time "$since" --max-results 25 --output json 2>/dev/null \
  | jq -r '["시각","이벤트","사용자","리소스"],
           (.Events[] | [(.EventTime|tostring)[11:19], .EventName,
                         (.Username // "-"), ((.Resources[0].ResourceName // "-")|.[0:40])])
           | @tsv' 2>/dev/null | tabalign \
  || warn "CloudTrail 조회 실패"
  read_it "Create·Delete·Modify 계열이 변경 이력이다. 의도하지 않은 삭제를 여기서 찾는다."
}

a8() {
  sec "${TITLES[8]}"
  ask "지표가 실제로 들어오는가. 대시보드 그래프의 근거 값을 직접 본다."
  local per=$(( MINUTES * 60 / 12 )); [ "$per" -lt 60 ] && per=60
  local st et
  st="$(date -u -d "-${MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)"
  et="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  metric() { # <네임스페이스> <지표> <차원> <라벨>
    local v
    v="$(aws cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" \
         --dimensions "$3" --start-time "$st" --end-time "$et" --period "$per" \
         --statistics Average Maximum --output json 2>/dev/null \
       | jq -r '.Datapoints | if length==0 then "데이터없음\t-" else
                 (sort_by(.Timestamp) | last | ((.Average*10|round)/10|tostring) + "\t" + ((.Maximum*10|round)/10|tostring)) end')"
    printf '%s\t%s\n' "$4" "$v"
  }
  {
    printf '지표\t평균\t최대\n'
    [ -n "${NGINX_ID:-}" ] && metric AWS/EC2 CPUUtilization "Name=InstanceId,Value=$NGINX_ID" "web CPU(%)"
    [ -n "${APP_A_ID:-}" ] && metric AWS/EC2 CPUUtilization "Name=InstanceId,Value=$APP_A_ID" "app-a CPU(%)"
    [ -n "${APP_C_ID:-}" ] && metric AWS/EC2 CPUUtilization "Name=InstanceId,Value=$APP_C_ID" "app-c CPU(%)"
    [ -n "${NGINX_ID:-}" ] && metric Capstone MemoryUtilization "Name=InstanceId,Value=$NGINX_ID" "web 메모리(%)"
    [ -n "${APP_A_ID:-}" ] && metric Capstone MemoryUtilization "Name=InstanceId,Value=$APP_A_ID" "app-a 메모리(%)"
    [ -n "${APP_C_ID:-}" ] && metric Capstone MemoryUtilization "Name=InstanceId,Value=$APP_C_ID" "app-c 메모리(%)"
    if [ -n "${DB_IDENTIFIER:-}" ]; then
      metric AWS/RDS CPUUtilization      "Name=DBInstanceIdentifier,Value=$DB_IDENTIFIER" "DB CPU(%)"
      metric AWS/RDS DatabaseConnections "Name=DBInstanceIdentifier,Value=$DB_IDENTIFIER" "DB 연결 수"
    fi
  } | tabalign
  printf '\n'
  read_it "메모리는 CloudWatch Agent 가 없으면 나오지 않는다. '데이터없음' 이면 에이전트를 점검할 것."
}

# ------------------------------------------------------------
banner "로그 분석 — 최근 ${MINUTES}분"
log "  대상: $N_LOGGROUP_APP / $N_LOGGROUP_FLOW / CloudTrail / CloudWatch 지표"

if [ -n "${1:-}" ]; then
  case "$1" in
    1|2|3|4|5|6|7|8) "a$1" ;;
    *) usage; exit 1 ;;
  esac
else
  for i in 1 2 3 4 5 6 7 8; do "a$i"; done
fi

banner "분석 마무리"
cat << 'GUIDE'
  데이터가 비어 있으면 트래픽을 만든 뒤 3~5분 기다리십시오.
    source state/cap.env
    for i in $(seq 1 40); do curl -s -o /dev/null http://$NGINX_IP/; done
    curl -s -o /dev/null http://$NGINX_IP/nowhere        # 404 유발
    curl -s -o /dev/null http://$NGINX_IP/static/x.png   # 404 유발

  기간을 넓히려면
    MINUTES=360 bash lab09-observability/analyze.sh

  항목 하나만 보려면
    bash lab09-observability/analyze.sh 5
GUIDE
