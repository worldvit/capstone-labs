#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 4  EC2 배치 및 3가지 접속 경로"

# Lab 10의 ASG가 같은 Project 태그를 달므로, 이름을 명시해 센다.
check_eq "Lab 4 EC2 3대 running" "3" bash -c \
  "aws ec2 describe-instances --filters Name=tag:Name,Values=$N_BASTION,$N_APP_A,$N_APP_C Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text"
check "Bastion 퍼블릭 IP 보유" bash -c \
  "[ -n \"\$(aws ec2 describe-instances --instance-ids ${BASTION_ID:-none} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)\" ]"
check_eq "App 서버 퍼블릭 IP 없음(app-a)" "None" bash -c \
  "aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"
check_eq "App 서버가 서로 다른 AZ에 배치" "2" bash -c \
  "aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} ${APP_C_ID:-none} --query 'Reservations[].Instances[].Placement.AvailabilityZone' --output text | tr '\t' '\n' | sort -u | grep -c ."
check_eq "인스턴스 프로파일 연결(app-a)" "$N_PROFILE_EC2" bash -c \
  "aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | awk -F/ '{print \$NF}'"
check_eq "IMDSv2 강제(app-a)" "required" bash -c \
  "aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text"
check_eq "SSM 관리형 인스턴스 2대 이상" "true" bash -c \
  "n=\$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=${APP_A_ID:-none},${APP_C_ID:-none} --query 'length(InstanceInformationList)' --output text); [ \"\$n\" -ge 2 ] && echo true || echo false"
check "AMI가 SSM 파라미터 최신본과 일치" bash -c \
  "[ \"\$(aws ssm get-parameter --name $AMI_SSM_PARAM --query Parameter.Value --output text)\" = \"\$(aws ec2 describe-instances --instance-ids ${APP_A_ID:-none} --query 'Reservations[0].Instances[0].ImageId' --output text)\" ]"
# NAT 경로가 실제로 살아 있는지 — SSM 등록이 그 증거다.
check_eq "App 서버 아웃바운드 경로 정상(NAT 경유)" "true" bash -c \
  "n=\$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=${APP_A_ID:-none} --query 'length(InstanceInformationList)' --output text); [ \"\$n\" -ge 1 ] && echo true || echo false"
if [ "${NAT_MODE_USED:-$NAT_MODE}" = "regional" ]; then
  check_eq "Regional NAT 가용성 모드 확인" "true" bash -c \
    "aws ec2 describe-nat-gateways --nat-gateway-ids ${NAT_SVC_A:-none} --output json \
     | jq -r '(.NatGateways[0].AvailabilityMode // \"zonal\") == \"regional\"'"
  # AZ 확장은 최대 60분 걸리므로 합격 조건으로 삼지 않고 현황만 표시한다.
  rnat_az_status "${NAT_SVC_A:-}" "서비스 VPC RNAT"
fi
check_summary
