#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 3  인터넷 경로 + 계층 보안 경계"

check_eq "IGW 2개 연결됨" "2" bash -c \
  "aws ec2 describe-internet-gateways --filters Name=tag:Owner,Values=$PREFIX Name=attachment.state,Values=available --query 'length(InternetGateways)' --output text"
check_eq "NAT 게이트웨이 4개 available" "4" bash -c \
  "aws ec2 describe-nat-gateways --filter Name=tag:Owner,Values=$PREFIX Name=state,Values=available --query 'length(NatGateways)' --output text"
check_eq "라우팅 테이블 8개" "8" bash -c \
  "aws ec2 describe-route-tables --filters Name=tag:Owner,Values=$PREFIX --query 'length(RouteTables)' --output text"
check_eq "퍼블릭 RT에 IGW 기본 경로" "1" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_SVC_PUB:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId,'igw-')])\" --output text"
check_eq "App-a RT에 NAT 기본 경로" "1" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_SVC_APP_A:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && NatGatewayId!=null])\" --output text"
check_eq "DB RT에 외부 경로 없음" "0" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_SVC_DB:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])\" --output text"
# JMESPath의 중첩 필터는 projection 위에서 항상 빈 결과를 낸다. jq로 판정한다.
sg_src() { # sg_src <검사대상SG> <포트> <기대소스SG>  → true/false
  aws ec2 describe-security-groups --group-ids "$1" --output json 2>/dev/null \
  | jq -r --argjson p "$2" --arg g "$3" \
      '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==$p) | .UserIdGroupPairs[].GroupId]
       | index($g) != null' 2>/dev/null
}
check_eq "app-sg가 alb-sg를 SG ID로 참조" "true" sg_src "${SG_APP:-none}" 80 "${SG_ALB:-none}"
# Lab 3 시점에는 TGW가 없어 교차 VPC SG 참조가 불가능하다. CIDR로 확인한다.
check_eq "app-sg 22가 관리 VPC CIDR 허용" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --output json \
   | jq -r '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==22) | .IpRanges[].CidrIp] | index(\"$VPC_MGMT_CIDR\") != null'"
check_eq "db-sg 3306이 app-sg를 참조" "true" sg_src "${SG_DB:-none}" 3306 "${SG_APP:-none}"
check_eq "db-sg 3306에 CIDR 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_DB:-none} --output json | jq '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==3306) | .IpRanges[]] | length'"
# 이 검사는 위반을 실제로 잡아내야 의미가 있다. JMESPath 중첩 필터는 무조건 0을 내므로 jq를 쓴다.
check_eq "SG에 0.0.0.0/0 SSH 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --filters Name=tag:Owner,Values=$PREFIX --output json \
   | jq '[.SecurityGroups[].IpPermissions[]
          | select((.FromPort // 0) <= 22 and (.ToPort // 65535) >= 22)
          | .IpRanges[] | select(.CidrIp==\"0.0.0.0/0\")] | length'"
check "App 계층 NACL 존재" bash -c "aws ec2 describe-network-acls --network-acl-ids ${NACL_SVC_APP:-none}"
check_summary
