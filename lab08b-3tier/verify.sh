#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 8.5  3-Tier 기본 (nginx → Tomcat → PostgreSQL)"

NIP="${NGINX_IP:-}"
if [ -z "$NIP" ] && [ -n "${NGINX_ID:-}" ]; then
  NIP="$(aws ec2 describe-instances --instance-ids "$NGINX_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)"
fi
log "  진입점: http://${NIP:-미확인}/"

# ---------- 계층별 리소스 ----------
check_eq "nginx 인스턴스 running" "running" bash -c \
  "aws ec2 describe-instances --instance-ids ${NGINX_ID:-none} --query 'Reservations[0].Instances[0].State.Name' --output text"
check_eq "nginx가 퍼블릭 서브넷에 배치" "${SN_SVC_PUB_A:-none}" bash -c \
  "aws ec2 describe-instances --instance-ids ${NGINX_ID:-none} --query 'Reservations[0].Instances[0].SubnetId' --output text"
check "nginx 퍼블릭 IP 보유" bash -c "[ -n \"$NIP\" ] && [ \"$NIP\" != None ]"
check_eq "App 서버는 퍼블릭 IP 없음" "None" bash -c \
  "aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"

# ---------- 보안 그룹 체인 ----------
sg_has_sg_src() { # <SG> <포트> <기대소스SG> → true/false
  aws ec2 describe-security-groups --group-ids "$1" --output json 2>/dev/null \
  | jq -r --argjson p "$2" --arg g "$3" \
      '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==$p) | .UserIdGroupPairs[].GroupId] | index($g) != null' 2>/dev/null
}
check_eq "web-sg 80 개방" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_WEB:-none} --output json \
   | jq -r '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==80) | .IpRanges[].CidrIp] | length > 0'"
check_eq "app-sg 8080 이 web-sg 참조" "true" sg_has_sg_src "${SG_APP:-none}" 8080 "${SG_WEB:-none}"
check_eq "app-sg 8080 에 CIDR 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --output json \
   | jq '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==8080) | .IpRanges[]] | length'"

# ---------- 계층 간 실제 흐름 ----------
# nginx 가 응답하는가 (Web 계층)
check "Web 계층 응답 (/web-health)" bash -c \
  "curl -fsS --max-time 10 http://${NIP:-invalid}/web-health | grep -q WEB_OK"
# Tomcat 이 응답하는가 (App 계층 — nginx 프록시 경유)
check "App 계층 응답 (/health, 프록시 경유)" bash -c \
  "curl -fsS --max-time 15 http://${NIP:-invalid}/health | grep -q OK"
# JSP 가 렌더링되는가
check "JSP 렌더링 및 App 인스턴스 표시" bash -c \
  "curl -fsS --max-time 20 http://${NIP:-invalid}/ | grep -q APP_INSTANCE"
# DB 조회가 성공하는가 (App → DB)
check_eq "DB 계층 조회 성공" "OK" bash -c \
  "curl -fsS --max-time 25 http://${NIP:-invalid}/ \
   | sed -n 's/.*DB_STATUS<\\/th><td>\\([^<]*\\).*/\\1/p' | head -1"

# ---------- 부하 분산 ----------
# nginx upstream 이 두 App 서버에 번갈아 보내는가
check_eq "두 App 서버가 번갈아 응답" "true" bash -c \
  "n=\$(for i in \$(seq 1 8); do
        curl -s --max-time 10 -H 'Connection: close' http://${NIP:-invalid}/ \
        | sed -n 's/.*APP_INSTANCE<\\/th><td>\\([^<]*\\).*/\\1/p'
      done | sort -u | grep -c .)
   [ \"\${n:-0}\" -ge 2 ] && echo true || echo false"

# ---------- 격리 ----------
# 인터넷에서 App 계층 8080 에 직접 닿으면 안 된다.
if [ -n "${APP_A_PIP:-}" ]; then
  check_eq "App 계층 직접 접근 차단(프라이빗 IP)" "BLOCKED" bash -c \
    "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${APP_A_PIP}/8080' 2>/dev/null && echo REACH || echo BLOCKED"
fi

check_summary
