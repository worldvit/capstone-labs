#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 5  VPC Endpoint + Transit Gateway"

check_eq "S3 Gateway Endpoint 존재" "Gateway" bash -c \
  "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${VPCE_S3:-none} --query 'VpcEndpoints[0].VpcEndpointType' --output text"
check_eq "S3 엔드포인트가 3개 라우팅 테이블에 연결" "3" bash -c \
  "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${VPCE_S3:-none} --query 'length(VpcEndpoints[0].RouteTableIds)' --output text"
check_eq "SSM Interface Endpoint 3종 available" "3" bash -c \
  "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${VPCE_SSM:-none} ${VPCE_SSMMSG:-none} ${VPCE_EC2MSG:-none} --query \"length(VpcEndpoints[?State=='available'])\" --output text"
check_eq "프라이빗 DNS 활성화(ssm)" "True" bash -c \
  "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${VPCE_SSM:-none} --query 'VpcEndpoints[0].PrivateDnsEnabled' --output text"
check_eq "TGW available" "available" bash -c \
  "aws ec2 describe-transit-gateways --transit-gateway-ids ${TGW_ID:-none} --query 'TransitGateways[0].State' --output text"
check_eq "TGW 어태치먼트 2개 available" "2" bash -c \
  "aws ec2 describe-transit-gateway-attachments --filters Name=transit-gateway-id,Values=${TGW_ID:-none} Name=state,Values=available --query 'length(TransitGatewayAttachments)' --output text"
check_eq "App-a RT에 관리 VPC 경로" "1" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_SVC_APP_A:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='$VPC_MGMT_CIDR' && TransitGatewayId!=null])\" --output text"
check_eq "관리 App-a RT에 서비스 VPC 경로" "1" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_MGMT_APP_A:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='$VPC_SVC_CIDR' && TransitGatewayId!=null])\" --output text"
check_eq "TGW 보안 그룹 참조 지원 활성" "enable" bash -c \
  "aws ec2 describe-transit-gateways --transit-gateway-ids ${TGW_ID:-none} --query 'TransitGateways[0].Options.SecurityGroupReferencingSupport' --output text"
check_eq "app-sg가 bastion-sg를 SG ID로 참조" "true" bash -c \
  "aws ec2 describe-security-groups --group-ids ${SG_APP:-none} --output json \
   | jq -r '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==22) | .UserIdGroupPairs[].GroupId] | index(\"${SG_BASTION:-none}\") != null'"
check_summary
