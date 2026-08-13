#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 8.5 teardown"
confirm_destroy "nginx EC2와 web-sg를 삭제합니다. Tomcat 구성은 App 서버에 남습니다."

if [ -n "${NGINX_ID:-}" ]; then
  soft aws ec2 terminate-instances --instance-ids "$NGINX_ID"
  aws ec2 wait instance-terminated --instance-ids "$NGINX_ID" 2>/dev/null || true
  ok "nginx EC2 종료: $NGINX_ID"
fi

# app-sg 의 8080 규칙(web-sg 참조)을 먼저 걷어야 web-sg 를 지울 수 있다.
if [ -n "${SG_APP:-}" ] && [ -n "${SG_WEB:-}" ]; then
  soft aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
    --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$SG_WEB}]"
  log "app-sg 8080 규칙 제거"
fi
[ -n "${SG_WEB:-}" ] && { soft aws ec2 delete-security-group --group-id "$SG_WEB"; ok "web-sg 삭제"; }

# 시크릿 읽기 권한 회수
soft aws iam delete-role-policy --role-name "$N_ROLE_EC2" --policy-name "${PREFIX}-read-db-secret"

for k in NGINX_ID NGINX_IP SG_WEB TOMCAT_CMD NGINX_CMD APP_A_PIP APP_C_PIP LAB08B_DONE; do
  drop_state "$k"
done
ok "Lab 8.5 teardown 완료"
