#!/bin/bash
# CloudWatch Agent 구성 — 지표(메모리·디스크)와 로그를 수집한다.
# build.sh가 base64로 인코딩해 SSM으로 전달한다.
set -uo pipefail
exec 2>&1
echo "=== CloudWatch Agent 구성 시작 ==="

LG_APP="__LG_APP__"
ROLE="__ROLE__"          # web | app

dnf -y install amazon-cloudwatch-agent >/dev/null 2>&1 || {
  echo "ERROR: amazon-cloudwatch-agent 설치 실패"; exit 1; }

# 역할에 따라 수집할 로그 파일이 다르다.
LOGS=""
if [ "$ROLE" = "web" ]; then
  LOGS='
          {"file_path":"/var/log/nginx/access.log","log_group_name":"__LG_APP__","log_stream_name":"{instance_id}/nginx/access"},
          {"file_path":"/var/log/nginx/error.log","log_group_name":"__LG_APP__","log_stream_name":"{instance_id}/nginx/error"}'
else
  # Tomcat 로그 위치는 패키지에 따라 다르므로 실제로 있는 것만 넣는다.
  CAT=""
  for c in /var/log/tomcat9/catalina.out /var/log/tomcat/catalina.out /var/log/tomcat9/catalina.*.log; do
    [ -f "$c" ] && { CAT="$c"; break; }
  done
  if [ -n "$CAT" ]; then
    LOGS='
          {"file_path":"'"$CAT"'","log_group_name":"__LG_APP__","log_stream_name":"{instance_id}/tomcat/catalina"}'
  else
    echo "WARN: Tomcat 로그 파일을 찾지 못했습니다. 지표만 수집합니다."
  fi
fi

# 로그 항목이 있을 때만 logs 블록을 넣는다(빈 배열은 에이전트가 거부한다).
LOGS_BLOCK=""
if [ -n "$LOGS" ]; then
  LOGS_BLOCK='
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": ['"$LOGS"'
        ]
      }
    }
  },'
fi

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/capstone.json << CFG
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },${LOGS_BLOCK}
  "metrics": {
    "namespace": "Capstone",
    "append_dimensions": { "InstanceId": "\${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem":  { "measurement": [{"name":"mem_used_percent","rename":"MemoryUtilization","unit":"Percent"}] },
      "disk": { "measurement": [{"name":"used_percent","rename":"DiskUtilization","unit":"Percent"}],
                "resources": ["/"], "ignore_file_system_types": ["sysfs","devtmpfs","tmpfs"] }
    }
  }
}
CFG

sed -i "s|__LG_APP__|${LG_APP}|g" /opt/aws/amazon-cloudwatch-agent/etc/capstone.json
python3 -c 'import json,sys;json.load(open("/opt/aws/amazon-cloudwatch-agent/etc/capstone.json"))' \
  || { echo "ERROR: 에이전트 설정 JSON이 올바르지 않습니다"; cat /opt/aws/amazon-cloudwatch-agent/etc/capstone.json; exit 1; }

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/capstone.json \
  || { echo "ERROR: 에이전트 설정 적용 실패"; exit 1; }

sleep 5
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status | head -10
systemctl is-active amazon-cloudwatch-agent >/dev/null 2>&1 \
  && echo "CloudWatch Agent 실행 중 (역할: $ROLE)" \
  || { echo "ERROR: 에이전트가 실행되지 않았습니다"; exit 1; }
echo "=== CloudWatch Agent 구성 완료 ==="
