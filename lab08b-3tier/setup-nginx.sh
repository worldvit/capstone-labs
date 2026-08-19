#!/usr/bin/env bash
# Web 계층 구성 — nginx 리버스 프록시
# build.sh가 base64로 인코딩해 SSM으로 전달한다.
set -uo pipefail
exec 2>&1
echo "=== Web 계층 구성 시작 ==="

UPSTREAMS="__UPSTREAMS__"      # 공백 구분: "10.1.10.5 10.1.11.7"

dnf -y install nginx >/dev/null 2>&1 || { echo "ERROR: nginx 설치 실패"; exit 1; }

# upstream 블록 생성
UP=""
for ip in $UPSTREAMS; do
  UP="${UP}    server ${ip}:8080 max_fails=2 fail_timeout=10s;
"
done
[ -n "$UP" ] || { echo "ERROR: upstream 대상이 없습니다"; exit 1; }

cat > /etc/nginx/conf.d/capstone.conf << CONF
# App 계층(Tomcat) 으로의 리버스 프록시
upstream tomcat_app {
${UP}}

server {
    listen 80 default_server;
    server_name _;

    # 웹 계층이 응답하는 경량 상태 검사 (App 계층과 구분하기 위한 경로)
    location = /web-health {
        access_log off;
        return 200 "WEB_OK\n";
        add_header Content-Type text/plain;
    }

    # 어느 웹 서버가 응답했는지 표시
    add_header X-Web-Tier \$hostname always;

    location / {
        proxy_pass http://tomcat_app;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout    30s;
    }
}
CONF

# 기본 서버 블록과 충돌하면 nginx가 뜨지 않는다.
if grep -q 'listen .*80 default_server' /etc/nginx/nginx.conf 2>/dev/null; then
  sed -i 's/listen\( \+\)80 default_server;/listen\1808 default_server;/' /etc/nginx/nginx.conf
  sed -i 's/listen\( \+\)\[::\]:80 default_server;/listen\1[::]:808 default_server;/' /etc/nginx/nginx.conf
  echo "기본 서버 블록 포트를 808로 이동(충돌 회피)"
fi

nginx -t || { echo "ERROR: nginx 설정 검증 실패"; exit 1; }
systemctl enable --now nginx
systemctl restart nginx
sleep 2
systemctl is-active nginx && echo "nginx 실행 중" || { echo "ERROR: nginx 시작 실패"; journalctl -u nginx -n 20 --no-pager; exit 1; }

echo "--- 자체 점검 ---"
curl -sf --max-time 5 http://127.0.0.1/web-health || echo "WARN: web-health 실패"
curl -sf --max-time 10 http://127.0.0.1/health  || echo "WARN: App 계층 상태 검사 실패 (Tomcat 확인 필요)"
echo "=== Web 계층 구성 완료 ==="
