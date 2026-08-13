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
# TGW가 실제로 트래픽을 나르는지 — 라우팅 존재만으로는 증명되지 않는다.
# 관리 VPC 퍼블릭 RT(Bastion이 있는 곳)에도 서비스 VPC 경로가 있어야 한다.
check_eq "관리 퍼블릭 RT에 서비스 VPC 경로" "1" bash -c \
  "aws ec2 describe-route-tables --route-table-ids ${RT_MGMT_PUB:-none} --query \"length(RouteTables[0].Routes[?DestinationCidrBlock=='$VPC_SVC_CIDR' && TransitGatewayId!=null])\" --output text"

# SSM 명령으로 Bastion에서 App 서버까지 실제 도달 여부를 확인한다(ICMP 규칙이 있을 때만 유효).
if [ "${TGW_PING_CHECK:-0}" = "1" ] && [ -n "${BASTION_ID:-}" ] && [ -n "${APP_A_ID:-}" ]; then
  check_eq "Bastion → App-a TGW 경유 도달" "Success" bash -c \
    "ip=\$(aws ec2 describe-instances --instance-ids ${APP_A_ID} --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
     cid=\$(aws ssm send-command --instance-ids ${BASTION_ID} --document-name AWS-RunShellScript \
            --parameters \"commands=['ping -c 3 -W 2 \$ip']\" --query 'Command.CommandId' --output text)
     for i in 1 2 3 4 5 6 7 8 9 10; do
       s=\$(aws ssm list-command-invocations --command-id \$cid --query 'CommandInvocations[0].Status' --output text 2>/dev/null)
       case \"\$s\" in Success|Failed|TimedOut) break ;; esac
       sleep 3
     done
     echo \"\$s\""
else
  log "  (TGW_PING_CHECK=1 로 실행하면 Bastion→App 실제 도달까지 확인합니다. ICMP 규칙 필요)"
fi
check_summary
