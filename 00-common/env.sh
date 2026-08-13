#!/usr/bin/env bash
# ============================================================
# env.sh — 캡스톤 랩 공통 환경 변수
# 모든 스크립트가 최초에 source 한다. 이 파일만 고치면 전체가 따라온다.
# ============================================================

# ---------- 필수: 실행 대상 지정 ----------
# 로컬 PC에서는 전용 프로파일을 강제해 기본 프로파일 혼용 사고를 막는다.
# CloudShell·EC2 인스턴스 역할처럼 앰비언트 자격 증명을 쓰는 환경에서는 강제하지 않는다.
if [ -n "${AWS_PROFILE:-}" ]; then
  export AWS_PROFILE                                   # 사용자가 명시한 값 존중
elif [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ] \
  || [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ] \
  || [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
  unset AWS_PROFILE                                    # 앰비언트 자격 증명 사용
else
  export AWS_PROFILE="capstone"
fi
export REGION="${REGION:-ap-northeast-2}"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""                              # 페이저 때문에 스크립트가 멈추는 것 방지

# 이 계정에서만 실행을 허용한다. guard.sh가 대조한다.
# 여러 계정에서 쓰려면 콤마로 나열: "676206941602,111122223333"
export EXPECTED_ACCOUNT_IDS="${EXPECTED_ACCOUNT_IDS:-454015599543}"

# ---------- 명명 접두사 ----------
# 공유 계정에서 학생별로 격리할 때:  PREFIX=st01 bash build-all.sh 5
# 전용/개인 계정:                    PREFIX=cap  (기본값)
export PREFIX="${PREFIX:-cap}"

# CIDR 2옥텟 기준값. 학생별 격리 시 STUDENT_BASE를 바꿔 충돌을 피한다.
#   STUDENT_BASE=1  -> svc 10.1.0.0/16, mgmt 10.2.0.0/16
#   STUDENT_BASE=11 -> svc 10.11.0.0/16, mgmt 10.12.0.0/16
export STUDENT_BASE="${STUDENT_BASE:-1}"
export OCT_SVC="$STUDENT_BASE"
export OCT_MGMT="$((STUDENT_BASE + 1))"

# ---------- 가용 영역 ----------
export AZ_A="${AZ_A:-${REGION}a}"
export AZ_C="${AZ_C:-${REGION}c}"

# ---------- 네트워크 ----------
export VPC_SVC_CIDR="10.${OCT_SVC}.0.0/16"
export VPC_MGMT_CIDR="10.${OCT_MGMT}.0.0/16"

export SN_SVC_PUB_A_CIDR="10.${OCT_SVC}.0.0/24"
export SN_SVC_PUB_C_CIDR="10.${OCT_SVC}.1.0/24"
export SN_SVC_APP_A_CIDR="10.${OCT_SVC}.10.0/24"
export SN_SVC_APP_C_CIDR="10.${OCT_SVC}.11.0/24"
export SN_SVC_DB_A_CIDR="10.${OCT_SVC}.20.0/24"
export SN_SVC_DB_C_CIDR="10.${OCT_SVC}.21.0/24"

export SN_MGMT_PUB_A_CIDR="10.${OCT_MGMT}.0.0/24"
export SN_MGMT_PUB_C_CIDR="10.${OCT_MGMT}.1.0/24"
export SN_MGMT_APP_A_CIDR="10.${OCT_MGMT}.10.0/24"
export SN_MGMT_APP_C_CIDR="10.${OCT_MGMT}.11.0/24"
export SN_MGMT_DB_A_CIDR="10.${OCT_MGMT}.20.0/24"
export SN_MGMT_DB_C_CIDR="10.${OCT_MGMT}.21.0/24"

# ---------- 리소스 이름 ----------
export N_VPC_SVC="${PREFIX}-vpc-svc"
export N_VPC_MGMT="${PREFIX}-vpc-mgmt"
export N_IGW_SVC="${PREFIX}-igw-svc"
export N_IGW_MGMT="${PREFIX}-igw-mgmt"
export N_TGW="${PREFIX}-tgw"

export N_SG_ALB="${PREFIX}-sg-alb"
export N_SG_APP="${PREFIX}-sg-app"
export N_SG_DB="${PREFIX}-sg-db"
export N_SG_BASTION="${PREFIX}-sg-bastion"
export N_SG_EFS="${PREFIX}-sg-efs"
export N_SG_VPCE="${PREFIX}-sg-vpce"

export N_ROLE_EC2="${PREFIX}-ec2-role"
export N_PROFILE_EC2="${PREFIX}-ec2-profile"
export N_GROUP_ADMIN="${PREFIX}-admin"
export N_GROUP_NETWORK="${PREFIX}-network"
export N_GROUP_APP="${PREFIX}-app"

export N_KEYPAIR="${PREFIX}-key"
export N_BASTION="${PREFIX}-bastion"
export N_APP_A="${PREFIX}-app-a"
export N_APP_C="${PREFIX}-app-c"

export N_EFS="${PREFIX}-efs"
export N_DB_SUBNET_GROUP="${PREFIX}-db-subnet-group"
export N_AURORA_CLUSTER="${PREFIX}-aurora"
export N_AURORA_WRITER="${PREFIX}-aurora-1"
export N_AURORA_READER="${PREFIX}-aurora-2"
export N_SECRET="${PREFIX}/aurora"

export N_ALB="${PREFIX}-alb"
export N_TG="${PREFIX}-tg"
export N_LT="${PREFIX}-lt"
export N_ASG="${PREFIX}-asg"

export N_TRAIL="${PREFIX}-trail"
export N_LOGGROUP_FLOW="/${PREFIX}/vpc-flowlogs"
export N_LOGGROUP_APP="/${PREFIX}/app"
export N_ROLE_FLOWLOG="${PREFIX}-flowlog-role"
export N_DASHBOARD="${PREFIX}-dashboard"
export N_SNS_ALERTS="${PREFIX}-alerts"

export N_SNS_EVENTS="${PREFIX}-events"
export N_SQS="${PREFIX}-queue"
export N_SQS_DLQ="${PREFIX}-dlq"
export N_LAMBDA="${PREFIX}-processor"
export N_ROLE_LAMBDA="${PREFIX}-lambda-role"
export N_APIGW="${PREFIX}-api"

export N_OAC="${PREFIX}-oac"
export N_WAF="${PREFIX}-waf"
export N_BACKUP_VAULT="${PREFIX}-vault"
export N_BACKUP_PLAN="${PREFIX}-plan"
export N_ROLE_BACKUP="${PREFIX}-backup-role"

# ---------- 데이터베이스 ----------
# Free Tier 계정은 백업 보존 기간이 1일로 제한된다(FreeTierRestrictionError).
# 유료 플랜이면 7 이상을 권장한다. build 스크립트가 실패 시 자동으로 1로 재시도한다.
export DB_BACKUP_RETENTION="${DB_BACKUP_RETENTION:-7}"
# Free Tier(무료 플랜) 계정은 aurora-postgresql 만 허용된다.
# build 스크립트가 FreeTierRestrictionError를 만나면 자동으로 전환한다.
export DB_ENGINE="${DB_ENGINE:-aurora-mysql}"

# DB_MODE=rds     : 일반 RDS 다중 AZ 배포. Free Tier 계정에서도 VPC 안에 만들 수 있다.
#                   기본 인스턴스 + 다른 AZ의 대기 인스턴스. 리더 엔드포인트는 없다.
# DB_MODE=aurora  : Aurora 클러스터(라이터 + 리더). 유료 플랜 필요.
export DB_MODE="${DB_MODE:-rds}"
export RDS_ENGINE="${RDS_ENGINE:-postgres}"          # postgres | mysql
export RDS_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t4g.micro}"
export RDS_STORAGE_GB="${RDS_STORAGE_GB:-20}"
export N_RDS="${PREFIX}-rds"

# ---------- NAT 방식 ----------
# regional : Regional NAT Gateway (2025-11 출시). VPC당 1개가 모든 AZ로 자동 확장.
#            퍼블릭 서브넷 불필요, EIP는 AWS가 관리. VPC 2개 → NAT 2개.
# zonal    : 기존 방식. AZ마다 퍼블릭 서브넷에 NAT 1개 + EIP 직접 할당. VPC 2개 → NAT 4개.
export NAT_MODE="${NAT_MODE:-regional}"

# ---------- EC2 ----------
export INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
# AMI는 절대 ID를 하드코딩하지 않는다. SSM 퍼블릭 파라미터로 조회한다.
export AMI_SSM_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# ---------- 알림 수신 주소 (Lab 9에서 구독) ----------
export ALERT_EMAIL="${ALERT_EMAIL:-}"

# ---------- state 동기화 ----------
# STATE_SYNC=1 이면 랩 완료마다 S3에 자동 백업하고, 시작 시 원격을 내려받는다.
export STATE_SYNC="${STATE_SYNC:-0}"
# 버킷 이름을 직접 쓰려면 지정. 미지정 시 ${PREFIX}-state-${ACCOUNT_ID}
export STATE_BUCKET="${STATE_BUCKET:-}"

# ---------- 경로 ----------
_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_ENV_DIR/.." && pwd)"; export ROOT_DIR
export COMMON_DIR="$ROOT_DIR/00-common"
export STATE_DIR="$ROOT_DIR/state"
export STATE_FILE="$STATE_DIR/${PREFIX}.env"

mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
