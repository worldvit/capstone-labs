#!/usr/bin/env bash
# ASG 노드 부팅 구성 — EFS 마운트 + Tomcat + JDBC + 진단 JSP
# build.sh가 base64로 인코딩해 시작 템플릿의 사용자 데이터에 넣는다.
set -uo pipefail
exec > /var/log/capstone-bootstrap.log 2>&1
echo "=== ASG 노드 부팅 구성 시작 $(date -Is) ==="

DB_SECRET_ARN="__DB_SECRET_ARN__"
DB_ENDPOINT="__DB_ENDPOINT__"
DB_PORT="__DB_PORT__"
DB_NAME="__DB_NAME__"
REGION="__REGION__"
EFS_ID="__EFS_ID__"

# ---------- 1. EFS 마운트 (여러 노드가 같은 파일을 본다) ----------
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "none" ]; then
  dnf -y install amazon-efs-utils || true
  mkdir -p /mnt/efs
  grep -q "$EFS_ID" /etc/fstab || echo "$EFS_ID:/ /mnt/efs efs _netdev,tls 0 0" >> /etc/fstab
  mountpoint -q /mnt/efs || mount -t efs -o tls "$EFS_ID:/" /mnt/efs || true
  mountpoint -q /mnt/efs || {
    dnf -y install nfs-utils
    mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
      "${EFS_ID}.efs.${REGION}.amazonaws.com:/" /mnt/efs || true
  }
  mountpoint -q /mnt/efs && echo "EFS 마운트 완료" || echo "WARN: EFS 마운트 실패"
fi

# ---------- 2. Tomcat ----------
TCPKG=""
for p in tomcat9 tomcat tomcat10; do
  dnf -y install "$p" && { TCPKG="$p"; break; }
done
[ -n "$TCPKG" ] || { echo "ERROR: Tomcat 설치 실패"; exit 1; }

TCSVC=""
for s in "$TCPKG" tomcat9 tomcat tomcat10; do
  for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
    [ -f "$d/${s}.service" ] && { TCSVC="$s"; break 2; }
  done
done
[ -n "$TCSVC" ] || { echo "ERROR: Tomcat 서비스 유닛 없음"; exit 1; }

WEBAPPS=""
for c in "/var/lib/${TCSVC}/webapps" "/usr/share/${TCSVC}/webapps"; do
  [ -d "$c" ] && { WEBAPPS="$c"; break; }
done
[ -n "$WEBAPPS" ] || WEBAPPS="$(find /var/lib /usr/share -maxdepth 3 -type d -name webapps | head -1)"
TCLIB=""
for c in "/usr/share/${TCSVC}/lib" "/var/lib/${TCSVC}/lib"; do
  [ -d "$c" ] && { TCLIB="$c"; break; }
done
TCUSER=tomcat; id "$TCSVC" >/dev/null 2>&1 && TCUSER="$TCSVC"
echo "서비스: $TCSVC / 계정: $TCUSER / webapps: $WEBAPPS"

# ---------- 3. JDBC 드라이버 ----------
JAR=""
dnf -y install postgresql-jdbc && JAR="$(find /usr/share/java -name 'postgresql*.jar' | head -1)"
if [ -z "$JAR" ]; then
  V=42.7.4
  curl -fsSL --retry 3 -o /tmp/pg.jar \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${V}/postgresql-${V}.jar" && JAR=/tmp/pg.jar
fi
[ -n "$JAR" ] && [ -n "$TCLIB" ] && cp -f "$JAR" "$TCLIB/postgresql.jar" && echo "JDBC 배치 완료"

# ---------- 4. DB 자격 증명 ----------
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
  chown root:"$(id -gn "$TCUSER" 2>/dev/null || echo root)" /etc/capstone/db.properties || true
  echo "DB 자격 증명 저장 완료"
else
  echo "WARN: Secrets Manager 조회 실패"
fi

# ---------- 5. 인스턴스 정보 ----------
TOKEN="$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
{
  echo "az=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
  echo "instanceId=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
  echo "privateIp=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)"
  echo "launchedBy=ASG"
} > /etc/capstone/app.properties
chmod 644 /etc/capstone/app.properties

# ---------- 6. JSP 배포 ----------
mkdir -p "$WEBAPPS/ROOT"
cat > "$WEBAPPS/ROOT/index.jsp" << 'JSP'
<%@ page import="java.sql.*,java.util.*,java.io.*" contentType="text/html;charset=UTF-8" %>
<%
  Properties app = new Properties();
  try (FileInputStream f = new FileInputStream("/etc/capstone/app.properties")) { app.load(f); } catch (Exception e) {}
  Properties db = new Properties();
  try (FileInputStream f = new FileInputStream("/etc/capstone/db.properties")) { db.load(f); } catch (Exception e) {}
  String dbStatus = "NOT_CONFIGURED", dbTime = "-", dbAddr = "-";
  if (db.getProperty("url") != null) {
    try {
      Class.forName("org.postgresql.Driver");
      try (Connection c = DriverManager.getConnection(db.getProperty("url"), db.getProperty("user"), db.getProperty("password"));
           Statement s = c.createStatement();
           ResultSet r = s.executeQuery("SELECT now()::text, coalesce(host(inet_server_addr()),'-')")) {
        if (r.next()) { dbTime = r.getString(1); dbAddr = r.getString(2); }
        dbStatus = "OK";
      }
    } catch (Throwable t) { dbStatus = "FAIL: " + t.getClass().getSimpleName(); }
  }
  String efs = "-";
  try (BufferedReader br = new BufferedReader(new FileReader("/mnt/efs/shared-note.txt"))) { efs = br.readLine(); } catch (Exception e) { efs = "(EFS 파일 없음)"; }
%>
<html><head><meta charset="utf-8"><title>capstone ALB+ASG</title>
<style>body{font-family:sans-serif;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.4rem .8rem;text-align:left}</style>
</head><body>
<h1>Capstone — ALB + ASG + EFS</h1>
<table>
<tr><th>APP_AZ</th><td><%= app.getProperty("az","-") %></td></tr>
<tr><th>APP_INSTANCE</th><td><%= app.getProperty("instanceId","-") %></td></tr>
<tr><th>APP_PRIVATE_IP</th><td><%= app.getProperty("privateIp","-") %></td></tr>
<tr><th>LAUNCHED_BY</th><td><%= app.getProperty("launchedBy","-") %></td></tr>
<tr><th>DB_STATUS</th><td><%= dbStatus %></td></tr>
<tr><th>DB_TIME</th><td><%= dbTime %></td></tr>
<tr><th>DB_SERVER_ADDR</th><td><%= dbAddr %></td></tr>
<tr><th>EFS_SHARED_NOTE</th><td><%= efs %></td></tr>
</table>
</body></html>
JSP
printf 'OK\n' > "$WEBAPPS/ROOT/health"
chown -R "$TCUSER":"$TCUSER" "$WEBAPPS/ROOT" || true

# EFS에 공유 파일이 없으면 첫 노드가 만든다. 모든 노드가 같은 값을 보게 된다.
if mountpoint -q /mnt/efs && [ ! -f /mnt/efs/shared-note.txt ]; then
  echo "EFS 공유 파일 생성: $(date -Is) by $(hostname)" > /mnt/efs/shared-note.txt
fi

systemctl enable --now "$TCSVC"
systemctl restart "$TCSVC"
for i in $(seq 1 12); do
  ss -tln | grep -q ':8080' && break
  sleep 5
done
curl -sf --max-time 10 http://127.0.0.1:8080/health && echo "상태 검사 통과" || echo "WARN: 상태 검사 실패"
echo "=== 부팅 구성 완료 $(date -Is) ==="
