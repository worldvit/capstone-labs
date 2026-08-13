#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 4 teardown"
confirm_destroy "EC2 3대와 키 페어를 삭제합니다."

IDS=""
for k in BASTION_ID APP_A_ID APP_C_ID; do id="${!k:-}"; [ -n "$id" ] && IDS="$IDS $id"; done
if [ -n "$IDS" ]; then
  soft aws ec2 terminate-instances --instance-ids $IDS
  aws ec2 wait instance-terminated --instance-ids $IDS 2>/dev/null || true
  ok "EC2 종료 완료"
fi
[ -n "${BASTION_EIP:-}" ] && soft aws ec2 release-address --allocation-id "$BASTION_EIP"
soft aws ec2 delete-key-pair --key-name "$N_KEYPAIR"
rm -f "$ROOT_DIR/state/keys/${N_KEYPAIR}.pem"

for k in BASTION_ID APP_A_ID APP_C_ID BASTION_EIP BASTION_IP KEYPAIR AMI_ID LAB04_DONE; do drop_state "$k"; done
ok "Lab 4 teardown 완료"
