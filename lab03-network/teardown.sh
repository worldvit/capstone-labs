#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 3 teardown"
confirm_destroy "NAT·EIP·라우팅 테이블·SG·NACL·IGW를 삭제합니다. (VPC·서브넷은 유지)"

# regional 모드에서는 NAT_SVC_C/NAT_MGMT_C가 같은 ID의 별칭이므로 중복 삭제를 피한다.
NAT_IDS="$(for k in NAT_SVC_A NAT_SVC_C NAT_MGMT_A NAT_MGMT_C; do
             id="${!k:-}"; [ -n "$id" ] && echo "$id"; done | sort -u)"
for id in $NAT_IDS; do
  soft aws ec2 delete-nat-gateway --nat-gateway-id "$id"; log "NAT 삭제 요청 $id"
done
for id in $NAT_IDS; do
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$id" 2>/dev/null || true
done
ok "NAT 삭제 완료"
# regional 모드는 AWS가 EIP를 관리하므로 해제할 것이 없다(상태 키도 비어 있음).
for k in NAT_SVC_A_EIP NAT_SVC_C_EIP NAT_MGMT_A_EIP NAT_MGMT_C_EIP; do
  id="${!k:-}"; [ -n "$id" ] || continue
  soft aws ec2 release-address --allocation-id "$id"; log "EIP 해제 $id"
done

[ -n "${NACL_SVC_APP:-}" ] && soft aws ec2 delete-network-acl --network-acl-id "$NACL_SVC_APP"

# SG는 상호 참조가 있어 규칙을 먼저 비운다
for k in SG_APP SG_DB SG_ALB SG_BASTION SG_VPCE; do
  id="${!k:-}"; [ -n "$id" ] || continue
  perms="$(aws ec2 describe-security-groups --group-ids "$id" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo '[]')"
  [ "$perms" != "[]" ] && soft aws ec2 revoke-security-group-ingress --group-id "$id" --ip-permissions "$perms" || true
done
for k in SG_APP SG_DB SG_ALB SG_BASTION SG_VPCE; do
  id="${!k:-}"; [ -n "$id" ] || continue
  soft aws ec2 delete-security-group --group-id "$id"; log "SG 삭제 $id"
done

for k in RT_SVC_PUB RT_SVC_APP_A RT_SVC_APP_C RT_SVC_DB RT_MGMT_PUB RT_MGMT_APP_A RT_MGMT_APP_C RT_MGMT_DB; do
  id="${!k:-}"; [ -n "$id" ] || continue
  for a in $(aws ec2 describe-route-tables --route-table-ids "$id" --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    soft aws ec2 disassociate-route-table --association-id "$a"
  done
  soft aws ec2 delete-route-table --route-table-id "$id"; log "RT 삭제 $id"
done

[ -n "${IGW_SVC:-}" ]  && { soft aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_SVC"  --vpc-id "${VPC_SVC:-}";  soft aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_SVC"; }
[ -n "${IGW_MGMT:-}" ] && { soft aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_MGMT" --vpc-id "${VPC_MGMT:-}"; soft aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_MGMT"; }

for k in IGW_SVC IGW_MGMT NAT_SVC_A NAT_SVC_C NAT_MGMT_A NAT_MGMT_C NAT_SVC_A_EIP NAT_SVC_C_EIP NAT_MGMT_A_EIP NAT_MGMT_C_EIP \
         RT_SVC_PUB RT_SVC_APP_A RT_SVC_APP_C RT_SVC_DB RT_MGMT_PUB RT_MGMT_APP_A RT_MGMT_APP_C RT_MGMT_DB \
         SG_ALB SG_APP SG_DB SG_BASTION SG_VPCE NACL_SVC_APP NAT_MODE_USED LAB03_DONE; do
  drop_state "$k"
done
ok "Lab 3 teardown 완료"
