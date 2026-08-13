#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 1 teardown"
confirm_destroy "Lab 1의 IAM 역할·그룹·정책을 삭제합니다."

soft aws iam remove-role-from-instance-profile --instance-profile-name "$N_PROFILE_EC2" --role-name "$N_ROLE_EC2"
soft aws iam delete-instance-profile --instance-profile-name "$N_PROFILE_EC2"
for arn in $(aws iam list-attached-role-policies --role-name "$N_ROLE_EC2" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  soft aws iam detach-role-policy --role-name "$N_ROLE_EC2" --policy-arn "$arn"
done
soft aws iam delete-role --role-name "$N_ROLE_EC2"

MFA_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PREFIX}-require-mfa"
for g in "$N_GROUP_ADMIN" "$N_GROUP_NETWORK" "$N_GROUP_APP"; do
  for arn in $(aws iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    soft aws iam detach-group-policy --group-name "$g" --policy-arn "$arn"
  done
  for u in $(aws iam get-group --group-name "$g" --query 'Users[].UserName' --output text 2>/dev/null); do
    soft aws iam remove-user-from-group --group-name "$g" --user-name "$u"
  done
  soft aws iam delete-group --group-name "$g"
done
soft aws iam delete-policy --policy-arn "$MFA_ARN"

drop_state ROLE_EC2; drop_state PROFILE_EC2; drop_state MFA_POLICY_ARN; drop_state LAB01_DONE
ok "Lab 1 teardown 완료"
