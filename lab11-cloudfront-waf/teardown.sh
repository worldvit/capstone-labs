#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 11 teardown"
confirm_destroy "CloudFront 배포와 WAF를 삭제합니다. 배포 비활성화에 15분 이상 걸립니다."

if [ -n "${CLOUDFRONT_ID:-}" ]; then
  ETAG="$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --query ETag --output text 2>/dev/null || true)"
  if [ -n "$ETAG" ]; then
    aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --query DistributionConfig > /tmp/${PREFIX}-cfg.json
    jq '.Enabled=false | .WebACLId=""' /tmp/${PREFIX}-cfg.json > /tmp/${PREFIX}-cfg-off.json
    soft aws cloudfront update-distribution --id "$CLOUDFRONT_ID" \
      --distribution-config file:///tmp/${PREFIX}-cfg-off.json --if-match "$ETAG"
    log "배포 비활성화 요청 — Deployed 대기"
    aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_ID" 2>/dev/null || true
    ETAG="$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --query ETag --output text)"
    soft aws cloudfront delete-distribution --id "$CLOUDFRONT_ID" --if-match "$ETAG"
    ok "배포 삭제 $CLOUDFRONT_ID"
  fi
fi
[ -n "${OAC_ID:-}" ] && {
  E="$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query ETag --output text 2>/dev/null || true)"
  [ -n "$E" ] && soft aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$E"; }
WID="${WAF_ID:-}"
[ -n "$WID" ] || WID="$(_q aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='$N_WAF'].Id | [0]" --output text)"
if [ -n "$WID" ]; then
  LT="$(aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name "$N_WAF" --id "$WID" --query LockToken --output text)"
  soft aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 --name "$N_WAF" --id "$WID" --lock-token "$LT"
  ok "WAF 삭제"
fi
[ -n "${CF_PREFIX_LIST:-}" ] && [ -n "${SG_ALB:-}" ] && soft aws ec2 revoke-security-group-ingress --group-id "$SG_ALB" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$CF_PREFIX_LIST}]"

# ALB 를 잠갔다면 0.0.0.0/0 을 되살려 Lab 10 상태로 돌린다.
if [ "${ALB_LOCKED:-0}" = "1" ] && [ -n "${SG_ALB:-}" ]; then
  soft aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
    --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]"
  log "ALB 80 개방 복구 (Lab 10 구성 복귀)"
fi

for k in CLOUDFRONT_ID CLOUDFRONT_DOMAIN OAC_ID WAF_ARN WAF_ID CF_PREFIX_LIST ALB_LOCKED LAB11_DONE; do
  drop_state "$k"
done
ok "Lab 11 teardown 완료"
