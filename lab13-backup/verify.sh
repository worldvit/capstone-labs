#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 13  백업 전략 및 복구"

check "백업 볼트 존재" aws backup describe-backup-vault --backup-vault-name "$N_BACKUP_VAULT"
check "백업 계획 존재" aws backup get-backup-plan --backup-plan-id "${BACKUP_PLAN_ID:-none}"
check_eq "백업 규칙 2개(일간/주간)" "2" bash -c \
  "aws backup get-backup-plan --backup-plan-id ${BACKUP_PLAN_ID:-none} --query 'length(BackupPlan.Rules)' --output text"
check_eq "태그 기반 선택 존재" "1" bash -c \
  "aws backup list-backup-selections --backup-plan-id ${BACKUP_PLAN_ID:-none} --query 'length(BackupSelectionsList)' --output text"
# 콘솔로 백업 계획을 만들면 AWS 가 AWSBackupDefaultServiceRole 을 쓴다.
# build.sh 로 만들면 cap-backup-role 이 생긴다. 둘 다 인정한다.
check "Backup 서비스 역할 존재" bash -c \
  "aws iam get-role --role-name $N_ROLE_BACKUP >/dev/null 2>&1 \
   || aws iam get-role --role-name AWSBackupDefaultServiceRole >/dev/null 2>&1"
# DB 배포 방식에 따라 조회 대상이 다르다.
if [ "${DB_MODE_USED:-$DB_MODE}" = "rds" ] && [ -n "${DB_IDENTIFIER:-}" ]; then
  check_eq "RDS 자동 백업 보존 ${DB_RETAIN_USED:-1}일" "${DB_RETAIN_USED:-1}" bash -c \
    "aws rds describe-db-instances --db-instance-identifier ${DB_IDENTIFIER} --query 'DBInstances[0].BackupRetentionPeriod' --output text"
elif [ -n "${AURORA_CLUSTER:-}" ]; then
  check_eq "Aurora 자동 백업 보존 ${DB_RETAIN_USED:-7}일" "${DB_RETAIN_USED:-7}" bash -c \
    "aws rds describe-db-clusters --db-cluster-identifier ${AURORA_CLUSTER} --query 'DBClusters[0].BackupRetentionPeriod' --output text"
fi
# 태그 기반 선택이 실제로 캡스톤 리소스를 잡는지 — 태그가 없으면 백업되지 않는다.
check_eq "캡스톤 리소스에 Project 태그" "true" bash -c \
  "n=\$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=capstone \
        --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo 0)
   n=\$(echo \"\$n\" | awk '{s+=\$1} END{print s+0}')
   [ \"\${n:-0}\" -ge 5 ] && echo true || echo false"
check_eq "웹 버킷 버전 관리 활성" "Enabled" bash -c \
  "aws s3api get-bucket-versioning --bucket ${BUCKET_WEB:-none} --query Status --output text"
check_summary
