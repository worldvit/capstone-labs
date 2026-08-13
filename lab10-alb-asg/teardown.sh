#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 10 teardown"
confirm_destroy "ALB·대상 그룹·ASG·시작 템플릿을 삭제합니다."

if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME:-$N_ASG}" --query 'length(AutoScalingGroups)' --output text 2>/dev/null | grep -q '^1$'; then
  soft aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG_NAME:-$N_ASG}" --min-size 0 --desired-capacity 0
  soft aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "${ASG_NAME:-$N_ASG}" --force-delete
  wait_until "ASG 삭제 완료" 600 20 bash -c \
    "[ \"\$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${ASG_NAME:-$N_ASG} --query 'length(AutoScalingGroups)' --output text)\" = '0' ]" || true
  ok "ASG 삭제"
fi
[ -n "${ALB_LISTENER_ARN:-}" ] && soft aws elbv2 delete-listener --listener-arn "$ALB_LISTENER_ARN"
[ -n "${ALB_ARN:-}" ] && { soft aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"; aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true; ok "ALB 삭제"; }
[ -n "${TARGET_GROUP_ARN:-}" ] && soft aws elbv2 delete-target-group --target-group-arn "$TARGET_GROUP_ARN"
soft aws ec2 delete-launch-template --launch-template-name "$N_LT"

# ALB 경로가 사라지므로 app-sg 의 8080(from alb-sg) 규칙도 걷는다.
if [ -n "${SG_APP:-}" ] && [ -n "${SG_ALB:-}" ]; then
  P="${APP_PORT_USED:-8080}"
  soft aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
    --ip-permissions "IpProtocol=tcp,FromPort=$P,ToPort=$P,UserIdGroupPairs=[{GroupId=$SG_ALB}]"
  log "app-sg $P 규칙(alb-sg) 제거"
fi

# nginx 를 폐기했다면 되살려 Lab 8.5 상태로 돌아가게 한다.
if [ "${NGINX_DECOMMISSIONED:-0}" = "1" ] && [ -n "${NGINX_ID:-}" ]; then
  soft aws ssm send-command --instance-ids "$NGINX_ID" --document-name AWS-RunShellScript \
    --parameters '{"commands":["systemctl enable --now nginx"]}'
  log "nginx 재기동 요청 (Lab 8.5 구성 복귀)"
fi

for k in ALB_ARN ALB_DNS ALB_LISTENER_ARN TARGET_GROUP_ARN ASG_NAME LAUNCH_TEMPLATE \
         APP_PORT_USED NGINX_DECOMMISSIONED LAB10_DONE; do drop_state "$k"; done
ok "Lab 10 teardown 완료"
