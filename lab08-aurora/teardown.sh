#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 8 teardown"

MODE="${DB_MODE_USED:-$DB_MODE}"
confirm_destroy "데이터베이스($MODE 모드)를 삭제합니다. 최종 스냅샷 없이 지웁니다."

if [ "$MODE" = "rds" ]; then
  DBID="${DB_IDENTIFIER:-$N_RDS}"
  if aws rds describe-db-instances --db-instance-identifier "$DBID" >/dev/null 2>&1; then
    # 삭제 보호가 켜져 있으면 먼저 해제해야 한다.
    soft aws rds modify-db-instance --db-instance-identifier "$DBID" \
      --no-deletion-protection --apply-immediately
    soft aws rds delete-db-instance --db-instance-identifier "$DBID" \
      --skip-final-snapshot --delete-automated-backups
    log "RDS 삭제 요청 $DBID (5~10분 소요)"
    aws rds wait db-instance-deleted --db-instance-identifier "$DBID" 2>/dev/null || true
    ok "RDS 삭제 완료"
  else
    log "RDS 인스턴스 없음: $DBID"
  fi
else
  for id in "$N_AURORA_READER" "$N_AURORA_WRITER"; do
    aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1 || continue
    soft aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups
    log "DB 인스턴스 삭제 요청 $id"
  done
  for id in "$N_AURORA_READER" "$N_AURORA_WRITER"; do
    aws rds wait db-instance-deleted --db-instance-identifier "$id" 2>/dev/null || true
  done
  if aws rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" >/dev/null 2>&1; then
    soft aws rds delete-db-cluster --db-cluster-identifier "$N_AURORA_CLUSTER" --skip-final-snapshot
    aws rds wait db-cluster-deleted --db-cluster-identifier "$N_AURORA_CLUSTER" 2>/dev/null || true
    ok "클러스터 삭제 완료"
  fi
fi

soft aws rds delete-db-subnet-group --db-subnet-group-name "$N_DB_SUBNET_GROUP"

for k in DB_IDENTIFIER DB_ENDPOINT DB_PORT_USED DB_SECRET_ARN DB_ENGINE_USED DB_MODE_USED \
         DB_RETAIN_USED DB_MULTIAZ_USED AURORA_CLUSTER AURORA_WRITER_EP AURORA_READER_EP LAB08_DONE; do
  drop_state "$k"
done
ok "Lab 8 teardown 완료"
