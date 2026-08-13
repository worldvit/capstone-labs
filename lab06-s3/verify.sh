#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 6  S3 정적 웹 + 엔드포인트 경유 접근"

check "웹 버킷 존재" aws s3api head-bucket --bucket "${BUCKET_WEB:-none}"
check "로그 버킷 존재" aws s3api head-bucket --bucket "${BUCKET_LOGS:-none}"
check_eq "웹 버킷 퍼블릭 액세스 완전 차단" "True" bash -c \
  "aws s3api get-public-access-block --bucket ${BUCKET_WEB:-none} --query 'PublicAccessBlockConfiguration.RestrictPublicBuckets' --output text"
check_eq "기본 암호화(AES256)" "AES256" bash -c \
  "aws s3api get-bucket-encryption --bucket ${BUCKET_WEB:-none} --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text"
check_eq "버전 관리 활성화" "Enabled" bash -c \
  "aws s3api get-bucket-versioning --bucket ${BUCKET_WEB:-none} --query Status --output text"
check "정적 콘텐츠 업로드됨" aws s3api head-object --bucket "${BUCKET_WEB:-none}" --key static/index.html
check "버킷 정책에 SourceVpce 조건 존재" bash -c \
  "aws s3api get-bucket-policy --bucket ${BUCKET_WEB:-none} --query Policy --output text | grep -q 'aws:SourceVpce'"
check "로그 버킷 수명 주기 규칙 존재" aws s3api get-bucket-lifecycle-configuration --bucket "${BUCKET_LOGS:-none}"
check_summary
