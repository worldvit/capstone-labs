#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 5 teardown"
confirm_destroy "VPC 엔드포인트 4개와 Transit Gateway를 삭제합니다."

EPS=""
for k in VPCE_S3 VPCE_SSM VPCE_SSMMSG VPCE_EC2MSG; do id="${!k:-}"; [ -n "$id" ] && EPS="$EPS $id"; done
[ -n "$EPS" ] && { soft aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS; ok "VPC 엔드포인트 삭제 요청"; }

for k in TGW_ATT_SVC TGW_ATT_MGMT; do
  id="${!k:-}"; [ -n "$id" ] || continue
  soft aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "$id"; log "TGW 어태치먼트 삭제 $id"
done
if [ -n "${TGW_ID:-}" ]; then
  wait_until "어태치먼트 삭제 완료" 600 20 bash -c \
    "[ \"\$(aws ec2 describe-transit-gateway-attachments --filters Name=transit-gateway-id,Values=$TGW_ID Name=state,Values=available,deleting,pending --query 'length(TransitGatewayAttachments)' --output text)\" = '0' ]" || true
  soft aws ec2 delete-transit-gateway --transit-gateway-id "$TGW_ID"; ok "TGW 삭제 요청 $TGW_ID"
fi

for k in VPCE_S3 VPCE_SSM VPCE_SSMMSG VPCE_EC2MSG TGW_ID TGW_ATT_SVC TGW_ATT_MGMT LAB05_DONE; do drop_state "$k"; done
ok "Lab 5 teardown 완료"
