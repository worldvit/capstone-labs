#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 2 teardown"
confirm_destroy "VPC 2개와 서브넷 12개를 삭제합니다. Lab 3 이후를 먼저 삭제해야 합니다."

for v in "${VPC_SVC:-}" "${VPC_MGMT:-}"; do
  [ -n "$v" ] || continue
  for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$v" --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    soft aws ec2 delete-subnet --subnet-id "$s"; log "서브넷 삭제 $s"
  done
  soft aws ec2 delete-vpc --vpc-id "$v"; ok "VPC 삭제 $v"
done

for k in VPC_SVC VPC_MGMT SN_SVC_PUB_A SN_SVC_PUB_C SN_SVC_APP_A SN_SVC_APP_C SN_SVC_DB_A SN_SVC_DB_C \
         SN_MGMT_PUB_A SN_MGMT_PUB_C SN_MGMT_APP_A SN_MGMT_APP_C SN_MGMT_DB_A SN_MGMT_DB_C LAB02_DONE; do
  drop_state "$k"
done
ok "Lab 2 teardown 완료"
