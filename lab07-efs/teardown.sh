#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 7 teardown"
confirm_destroy "EFS 파일 시스템과 마운트 대상을 삭제합니다. 저장된 데이터는 복구되지 않습니다."

[ -n "${EFS_AP:-}" ] && soft aws efs delete-access-point --access-point-id "$EFS_AP"
if [ -n "${EFS_ID:-}" ]; then
  for mt in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null); do
    soft aws efs delete-mount-target --mount-target-id "$mt"; log "마운트 대상 삭제 $mt"
  done
  wait_until "마운트 대상 삭제 완료" 300 10 bash -c \
    "[ \"\$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)\" = '0' ]" || true
  soft aws efs delete-file-system --file-system-id "$EFS_ID"; ok "EFS 삭제 $EFS_ID"
fi
[ -n "${SG_EFS:-}" ] && soft aws ec2 delete-security-group --group-id "$SG_EFS"

for k in EFS_ID EFS_AP SG_EFS EFS_MOUNT_CMD LAB07_DONE; do drop_state "$k"; done
ok "Lab 7 teardown 완료"
