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
check_eq "app-sg가 alb-sg를 SG ID로 참조" "1" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --query \"length(SecurityGroups[0].IpPermissions[?FromPort==\\\`80\\\`].UserIdGroupPairs[?GroupId=='${SG_ALB:-none}'] | [])\" --output text"
check_eq "db-sg 3306이 app-sg만 허용" "1" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_DB:-none} --query \"length(SecurityGroups[0].IpPermissions[?FromPort==\\\`3306\\\`].UserIdGroupPairs[?GroupId=='${SG_APP:-none}'] | [])\" --output text"
check_eq "SG에 0.0.0.0/0 SSH 개방 없음" "0" bash -c \
  "aws ec2 describe-security-groups --filters Name=tag:Owner,Values=$PREFIX --query \"length(SecurityGroups[].IpPermissions[?FromPort==\\\`22\\\`].IpRanges[?CidrIp=='0.0.0.0/0'] | [] | [])\" --output text"
check "App 계층 NACL 존재" bash -c "aws ec2 describe-network-acls --network-acl-ids ${NACL_SVC_APP:-none}"
check_summary
