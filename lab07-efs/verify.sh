#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 7  EFS 공유 스토리지"

check_eq "EFS available" "available" bash -c \
  "aws efs describe-file-systems --file-system-id ${EFS_ID:-none} --query 'FileSystems[0].LifeCycleState' --output text"
check_eq "저장 시 암호화" "True" bash -c \
  "aws efs describe-file-systems --file-system-id ${EFS_ID:-none} --query 'FileSystems[0].Encrypted' --output text"
check_eq "마운트 대상 2개 available" "2" bash -c \
  "aws efs describe-mount-targets --file-system-id ${EFS_ID:-none} --query \"length(MountTargets[?LifeCycleState=='available'])\" --output text"
check_eq "마운트 대상이 서로 다른 AZ" "2" bash -c \
  "aws efs describe-mount-targets --file-system-id ${EFS_ID:-none} --query 'MountTargets[].AvailabilityZoneName' --output text | tr '\t' '\n' | sort -u | grep -c ."
check_eq "efs-sg가 app-sg를 2049 소스로 참조" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_EFS:-none} --output json \
   | jq -r '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==2049) | .UserIdGroupPairs[].GroupId] | index(\"${SG_APP:-none}\") != null'"
check_eq "efs-sg 2049에 CIDR 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_EFS:-none} --output json \
   | jq '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==2049) | .IpRanges[]] | length'"
check "액세스 포인트 존재" bash -c \
  "aws efs describe-access-points --access-point-id ${EFS_AP:-none}"
# EFS 프라이빗 DNS는 VPC의 DNS 지원·호스트네임이 모두 켜져야 해석된다.
# 꺼져 있으면 마운트 대상이 있어도 mount가 실패한다.
check_eq "VPC DNS 지원 활성화" "True" bash -c \
  "aws ec2 describe-vpc-attribute --vpc-id ${VPC_SVC:-none} --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text"
check_eq "VPC DNS 호스트네임 활성화" "True" bash -c \
  "aws ec2 describe-vpc-attribute --vpc-id ${VPC_SVC:-none} --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text"
if [ -n "${APP_A_ID:-}" ] && [ -n "${EFS_ID:-}" ]; then
  check_eq "App 서버에서 EFS DNS 해석" "Success" bash -c "
    c=\$(aws ssm send-command --instance-ids ${APP_A_ID} --document-name AWS-RunShellScript \
         --parameters \"commands=['getent hosts ${EFS_ID}.efs.${REGION}.amazonaws.com']\" \
         --query Command.CommandId --output text 2>/dev/null) || exit 1
    for i in \$(seq 1 15); do
      s=\$(aws ssm list-command-invocations --command-id \$c --query 'CommandInvocations[0].Status' --output text 2>/dev/null)
      case \"\$s\" in Success|Failed|TimedOut) echo \"\$s\"; exit 0 ;; esac
      sleep 3
    done
    echo TIMEOUT"
fi
if [ -n "${EFS_MOUNT_CMD:-}" ]; then
  check_eq "SSM 마운트 명령 성공" "Success" bash -c \
    "aws ssm list-command-invocations --command-id ${EFS_MOUNT_CMD} --query 'CommandInvocations[0].Status' --output text"
fi
# 이 랩의 핵심 주장: 한 AZ에서 쓴 파일이 다른 AZ에서 읽힌다.
# 마운트 존재만으로는 증명되지 않으므로 실제로 쓰고 읽는다.
if [ "${EFS_SHARE_CHECK:-1}" = "1" ] && [ -n "${APP_A_ID:-}" ] && [ -n "${APP_C_ID:-}" ]; then
  check_eq "AZ 간 파일 공유 동작" "OK" bash -c '
    TAG="capstone-$(date +%s)"
    w=$(aws ssm send-command --instance-ids '"${APP_A_ID}"' --document-name AWS-RunShellScript         --parameters "commands=["echo $TAG > /mnt/efs/share-test.txt"]"         --query Command.CommandId --output text 2>/dev/null) || exit 1
    for i in $(seq 1 20); do
      s=$(aws ssm list-command-invocations --command-id $w --query "CommandInvocations[0].Status" --output text 2>/dev/null)
      case "$s" in Success) break ;; Failed|TimedOut|Cancelled) echo "WRITE_$s"; exit 0 ;; esac
      sleep 3
    done
    r=$(aws ssm send-command --instance-ids '"${APP_C_ID}"' --document-name AWS-RunShellScript         --parameters "commands=["grep -q $TAG /mnt/efs/share-test.txt && echo MATCH"]"         --query Command.CommandId --output text 2>/dev/null) || exit 1
    for i in $(seq 1 20); do
      s=$(aws ssm list-command-invocations --command-id $r --query "CommandInvocations[0].Status" --output text 2>/dev/null)
      case "$s" in Success) echo OK; exit 0 ;; Failed|TimedOut|Cancelled) echo "READ_$s"; exit 0 ;; esac
      sleep 3
    done
    echo TIMEOUT'
else
  log "  (EFS_SHARE_CHECK=0 이거나 App 서버가 없어 AZ 간 공유 검사를 건너뜁니다)"
fi
check_summary
