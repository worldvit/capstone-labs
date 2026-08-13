#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 1  계정 기반 + IAM 권한 체계"

check "IAM 역할 $N_ROLE_EC2 존재" aws iam get-role --role-name "$N_ROLE_EC2"
check_eq "역할에 SSM 정책 연결" "1" bash -c \
  "aws iam list-attached-role-policies --role-name $N_ROLE_EC2 --query \"length(AttachedPolicies[?PolicyName=='AmazonSSMManagedInstanceCore'])\" --output text"
check "인스턴스 프로파일 $N_PROFILE_EC2 존재" aws iam get-instance-profile --instance-profile-name "$N_PROFILE_EC2"
check_eq "프로파일에 역할 결합" "$N_ROLE_EC2" bash -c \
  "aws iam get-instance-profile --instance-profile-name $N_PROFILE_EC2 --query 'InstanceProfile.Roles[0].RoleName' --output text"
for g in "$N_GROUP_ADMIN" "$N_GROUP_NETWORK" "$N_GROUP_APP"; do
  check "그룹 $g 존재" aws iam get-group --group-name "$g"
done
check "MFA 강제 정책 존재" aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${PREFIX}-require-mfa"
check_summary
