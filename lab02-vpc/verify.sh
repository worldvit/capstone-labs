#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 2  멀티 VPC + 멀티 AZ 3계층 서브넷"

check_eq "VPC 2개 존재" "2" bash -c \
  "aws ec2 describe-vpcs --filters Name=tag:Project,Values=capstone Name=tag:Owner,Values=$PREFIX --query 'length(Vpcs)' --output text"
check_eq "서비스 VPC CIDR" "$VPC_SVC_CIDR" bash -c \
  "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$N_VPC_SVC --query 'Vpcs[0].CidrBlock' --output text"
check_eq "관리 VPC CIDR" "$VPC_MGMT_CIDR" bash -c \
  "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$N_VPC_MGMT --query 'Vpcs[0].CidrBlock' --output text"
check_eq "서브넷 12개 존재" "12" bash -c \
  "aws ec2 describe-subnets --filters Name=tag:Project,Values=capstone Name=tag:Owner,Values=$PREFIX --query 'length(Subnets)' --output text"
check_eq "서비스 VPC가 2개 AZ에 분산" "2" bash -c \
  "aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_SVC:-none} --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | grep -c ."
check_eq "관리 VPC가 2개 AZ에 분산" "2" bash -c \
  "aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_MGMT:-none} --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | grep -c ."
check_eq "서비스 VPC 서브넷 6개" "6" bash -c \
  "aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_SVC:-none} --query 'length(Subnets)' --output text"
check_eq "DNS 호스트네임 활성화(svc)" "True" bash -c \
  "aws ec2 describe-vpc-attribute --vpc-id ${VPC_SVC:-none} --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text"
check_summary
