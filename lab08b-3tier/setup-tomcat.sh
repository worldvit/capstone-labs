#!/usr/bin/env bash
# App 계층 구성 — Tomcat + PostgreSQL JDBC + 진단 JSP
# 이 스크립트는 build.sh가 base64로 인코딩해 SSM으로 전달한다.
set -uo pipefail
exec 2>&1
echo "=== App 계층 구성 시작 ==="

DB_SECRET_ARN="__DB_SECRET_ARN__"
DB_ENDPOINT="__DB_ENDPOINT__"
DB_PORT="__DB_PORT__"
DB_NAME="__DB_NAME__"
REGION="__REGION__"

# ---------- 1. Tomcat 설치 ----------
TCPKG=""
for p in tomcat9 tomcat tomcat10; do
  if dnf -y install "$p" >/dev/null 2>&1; then TCPKG="$p"; break; fi
done
[ -n "$TCPKG" ] || { echo "ERROR: Tomcat 패키지를 설치할 수 없습니다"; exit 1; }
echo "Tomcat 패키지: $TCPKG"

# 서비스명 탐지 — systemctl 출력 형식에 의존하지 않고 유닛 파일 존재로 판단한다.
# (list-unit-files 파싱은 환경에 따라 형식이 달라 신뢰할 수 없다)
TCSVC=""
for s in "$TCPKG" tomcat9 tomcat tomcat10; do
  for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
    [ -f "$d/${s}.service" ] && { TCSVC="$s"; break 2; }
  done
done
if [ -z "$TCSVC" ]; then
  echo "ERROR: Tomcat 서비스 유닛을 찾을 수 없습니다. 설치된 유닛:"
  ls -1 /usr/lib/systemd/system/ 2>/dev/null | grep -i tomcat || echo "  (없음)"
  exit 1
fi

# 경로 탐지 — 패키지가 tomcat9 면 /var/lib/tomcat9, /usr/share/tomcat9 를 쓴다.
WEBAPPS=""
for c in "/var/lib/${TCSVC}/webapps" "/usr/share/${TCSVC}/webapps" "/var/lib/tomcat/webapps"; do
  [ -d "$c" ] && { WEBAPPS="$c"; break; }
done
[ -n "$WEBAPPS" ] || WEBAPPS="$(find /var/lib /usr/share -maxdepth 3 -type d -name webapps 2>/dev/null | head -1)"
[ -n "$WEBAPPS" ] || { echo "ERROR: webapps 디렉터리를 찾을 수 없습니다"; exit 1; }

TCLIB=""
for c in "/usr/share/${TCSVC}/lib" "/var/lib/${TCSVC}/lib"; do
  [ -d "$c" ] && { TCLIB="$c"; break; }
done
[ -n "$TCLIB" ] || TCLIB="$(find /usr/share -maxdepth 3 -type d -path '*tomcat*' -name lib 2>/dev/null | head -1)"

# 서비스 계정도 패키지에 따라 다르다.
TCUSER=tomcat
id "$TCSVC" >/dev/null 2>&1 && TCUSER="$TCSVC"
echo "서비스: $TCSVC / 계정: $TCUSER / webapps: $WEBAPPS / lib: ${TCLIB:-미탐지}"

# ---------- 2. PostgreSQL JDBC 드라이버 ----------
JAR=""
if dnf -y install postgresql-jdbc >/dev/null 2>&1; then
  JAR="$(find /usr/share/java -name 'postgresql*.jar' 2>/dev/null | head -1)"
fi
if [ -z "$JAR" ]; then
  echo "저장소에 드라이버 없음 — Maven Central에서 내려받습니다"
  V=42.7.4
  curl -fsSL --retry 3 -o /tmp/pg.jar \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${V}/postgresql-${V}.jar" && JAR=/tmp/pg.jar
fi
if [ -n "$JAR" ] && [ -n "$TCLIB" ]; then
  cp -f "$JAR" "$TCLIB/postgresql.jar"
  echo "JDBC 드라이버 배치: $TCLIB/postgresql.jar"
else
  echo "WARN: JDBC 드라이버를 배치하지 못했습니다. DB 조회는 실패합니다."
fi

# ---------- 3. DB 자격 증명 (Secrets Manager) ----------
mkdir -p /etc/capstone
SEC="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
       --region "$REGION" --query SecretString --output text 2>/dev/null || echo '')"
if [ -n "$SEC" ]; then
  DBU="$(echo "$SEC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["username"])')"
  DBP="$(echo "$SEC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')"
  cat > /etc/capstone/db.properties << PROPS
url=jdbc:postgresql://${DB_ENDPOINT}:${DB_PORT}/${DB_NAME}
user=${DBU}
password=${DBP}
PROPS
  chmod 640 /etc/capstone/db.properties
  chown root:"$(id -gn "$TCUSER" 2>/dev/null || echo root)" /etc/capstone/db.properties 2>/dev/null || true
  echo "DB 자격 증명 저장 완료 (/etc/capstone/db.properties)"
else
  echo "WARN: Secrets Manager 조회 실패 — EC2 역할 권한을 확인하십시오"
fi

# ---------- 4. 인스턴스 정보 ----------
TOKEN="$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
AZ="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
IID="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
PIP="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)"
cat > /etc/capstone/app.properties << APROPS
az=${AZ}
instanceId=${IID}
privateIp=${PIP}
APROPS
chmod 644 /etc/capstone/app.properties

# ---------- 5. 진단 JSP 배포 ----------
mkdir -p "$WEBAPPS/ROOT"
cat > "$WEBAPPS/ROOT/index.jsp" << 'JSP'
<%@ page import="java.sql.*,java.util.*,java.io.*" contentType="text/html;charset=UTF-8" %>
<%
  Properties app = new Properties();
  try (FileInputStream f = new FileInputStream("/etc/capstone/app.properties")) { app.load(f); } catch (Exception e) {}
  Properties db = new Properties();
  try (FileInputStream f = new FileInputStream("/etc/capstone/db.properties")) { db.load(f); } catch (Exception e) {}

  String dbStatus = "NOT_CONFIGURED", dbTime = "-", dbAddr = "-", dbVer = "-";
  if (db.getProperty("url") != null) {
    try {
      Class.forName("org.postgresql.Driver");
      try (Connection c = DriverManager.getConnection(db.getProperty("url"), db.getProperty("user"), db.getProperty("password"));
           Statement s = c.createStatement();
           ResultSet r = s.executeQuery("SELECT now()::text, coalesce(host(inet_server_addr()),'-'), version()")) {
        if (r.next()) { dbTime = r.getString(1); dbAddr = r.getString(2); dbVer = r.getString(3); }
        dbStatus = "OK";
      }
    } catch (Throwable t) { dbStatus = "FAIL: " + t.getClass().getSimpleName() + " " + t.getMessage(); }
  }
%>
<html><head><meta charset="utf-8"><title>capstone 3-tier</title>
<style>body{font-family:sans-serif;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.4rem .8rem;text-align:left}</style>
</head><body>
<h1>Capstone 3-Tier</h1>
<h2>App 계층 (Tomcat)</h2>
<table>
<tr><th>APP_AZ</th><td><%= app.getProperty("az","-") %></td></tr>
<tr><th>APP_INSTANCE</th><td><%= app.getProperty("instanceId","-") %></td></tr>
<tr><th>APP_PRIVATE_IP</th><td><%= app.getProperty("privateIp","-") %></td></tr>
</table>
<h2>DB 계층 (PostgreSQL)</h2>
<table>
<tr><th>DB_STATUS</th><td><%= dbStatus %></td></tr>
<tr><th>DB_TIME</th><td><%= dbTime %></td></tr>
<tr><th>DB_SERVER_ADDR</th><td><%= dbAddr %></td></tr>
<tr><th>DB_VERSION</th><td><%= dbVer %></td></tr>
</table>
</body></html>
JSP

# 상태 검사용 (ALB·nginx가 쓰는 경량 경로)
printf 'OK\n' > "$WEBAPPS/ROOT/health"

chown -R "$TCUSER":"$TCUSER" "$WEBAPPS/ROOT" 2>/dev/null || true

systemctl enable --now "$TCSVC"
systemctl restart "$TCSVC"
sleep 5
if systemctl is-active --quiet "$TCSVC"; then
  echo "Tomcat 실행 중 ($TCSVC)"
else
  echo "ERROR: Tomcat 시작 실패"
  systemctl status "$TCSVC" --no-pager -l 2>&1 | head -20
  journalctl -u "$TCSVC" -n 30 --no-pager 2>&1 | tail -30
  exit 1
fi

# 8080 리스닝까지 최대 60초 기다린다. JVM 기동에 시간이 걸린다.
for i in $(seq 1 12); do
  ss -tln 2>/dev/null | grep -q ':8080' && { echo "8080 리스닝 확인 (${i}회차)"; break; }
  sleep 5
done
ss -tln 2>/dev/null | grep -q ':8080' || { echo "WARN: 8080 미리스닝"; journalctl -u "$TCSVC" -n 20 --no-pager | tail -20; }
curl -sf --max-time 10 http://127.0.0.1:8080/health && echo "자체 상태 검사 통과" || echo "WARN: 자체 상태 검사 실패"
echo "=== App 계층 구성 완료 ==="
