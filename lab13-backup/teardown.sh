#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 13 teardown"
confirm_destroy "백업 계획·선택·볼트를 삭제합니다. 볼트 안의 복구 지점도 함께 삭제됩니다."

if [ -n "${BACKUP_PLAN_ID:-}" ]; then
  for s in $(aws backup list-backup-selections --backup-plan-id "$BACKUP_PLAN_ID" --query 'BackupSelectionsList[].SelectionId' --output text 2>/dev/null); do
    soft aws backup delete-backup-selection --backup-plan-id "$BACKUP_PLAN_ID" --selection-id "$s"
  done
  soft aws backup delete-backup-plan --backup-plan-id "$BACKUP_PLAN_ID"; ok "백업 계획 삭제"
fi
for rp in $(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$N_BACKUP_VAULT" --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null); do
  soft aws backup delete-recovery-point --backup-vault-name "$N_BACKUP_VAULT" --recovery-point-arn "$rp"
done
soft aws backup delete-backup-vault --backup-vault-name "$N_BACKUP_VAULT"
for P in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForRestores; do
  soft aws iam detach-role-policy --role-name "$N_ROLE_BACKUP" --policy-arn "arn:aws:iam::aws:policy/service-role/$P"
done
soft aws iam delete-role --role-name "$N_ROLE_BACKUP"

for k in BACKUP_PLAN_ID BACKUP_ROLE_ARN BACKUP_JOB_ID LAB13_DONE; do drop_state "$k"; done
ok "Lab 13 teardown 완료"
