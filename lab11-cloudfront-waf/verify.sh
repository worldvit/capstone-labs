#!/usr/bin/env bash
source "$(dirname "$0")/../00-common/bootstrap.sh"
check_begin "Lab 11  CloudFront + S3 + WAF"

CF="${CLOUDFRONT_DOMAIN:-invalid}"
DIST="${CLOUDFRONT_ID:-none}"
log "  배포: https://${CF}/"

# ---------- 배포 구성 ----------
check_eq "배포 Enabled" "True" bash -c \
  "aws cloudfront get-distribution --id $DIST --query 'Distribution.DistributionConfig.Enabled' --output text"
check_eq "배포 상태 Deployed" "Deployed" bash -c \
  "aws cloudfront get-distribution --id $DIST --query 'Distribution.Status' --output text"
# Lab 12 가 /api/* 용 오리진을 추가하므로 개수가 늘 수 있다. 필수 오리진의 존재로 판정한다.
check_eq "ALB 오리진 존재" "true" bash -c \
  "aws cloudfront get-distribution --id $DIST --output json \
   | jq -e '[.Distribution.DistributionConfig.Origins.Items[] | select(.Id==\"alb-origin\")] | length > 0'"
check_eq "S3 오리진 존재" "true" bash -c \
  "aws cloudfront get-distribution --id $DIST --output json \
   | jq -e '[.Distribution.DistributionConfig.Origins.Items[] | select(.Id==\"s3-origin\")] | length > 0'"
check_eq "/static/* 캐시 동작 존재" "/static/*" bash -c \
  "aws cloudfront get-distribution --id $DIST --query 'Distribution.DistributionConfig.CacheBehaviors.Items[0].PathPattern' --output text"
check_eq "S3 오리진에 OAC 연결" "${OAC_ID:-none}" bash -c \
  "aws cloudfront get-distribution --id $DIST --query \"Distribution.DistributionConfig.Origins.Items[?Id=='s3-origin'].OriginAccessControlId | [0]\" --output text"
check_eq "뷰어 프로토콜 HTTPS 리디렉션" "redirect-to-https" bash -c \
  "aws cloudfront get-distribution --id $DIST --query 'Distribution.DistributionConfig.DefaultCacheBehavior.ViewerProtocolPolicy' --output text"

# ---------- WAF ----------
check_eq "WAF가 us-east-1 CLOUDFRONT 범위에 존재" "1" bash -c \
  "aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query \"length(WebACLs[?Name=='$N_WAF'])\" --output text"
check_eq "배포에 WAF 연결" "${WAF_ARN:-none}" bash -c \
  "aws cloudfront get-distribution --id $DIST --query 'Distribution.DistributionConfig.WebACLId' --output text"
# 새 콘솔의 "보호 팩" 흐름은 앱 카테고리에 맞춰 규칙을 자동으로 채운다(19개 이상).
# 그래서 개수를 못 박지 않고 "필수 세 종류가 들어 있는가"를 본다.
check_eq "WAF 필수 규칙 3종 포함" "3" bash -c \
  "aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name $N_WAF --id ${WAF_ID:-none} --output json \
   | python3 -c \"import sys,json; r=json.load(sys.stdin)['WebACL']['Rules']; d=json.dumps(r); print(sum([('CommonRuleSet' in d),('KnownBadInputs' in d),('RateBasedStatement' in d)]))\""

# ---------- S3 버킷 정책 ----------
check "버킷 정책에 OAC 조건 존재" bash -c \
  "aws s3api get-bucket-policy --bucket ${BUCKET_WEB:-none} --query Policy --output text | grep -q 'cloudfront.amazonaws.com'"
check "버킷 정책에 엔드포인트 조건 유지" bash -c \
  "aws s3api get-bucket-policy --bucket ${BUCKET_WEB:-none} --query Policy --output text | grep -q 'aws:SourceVpce'"
check_eq "버킷 퍼블릭 액세스 차단 유지" "True" bash -c \
  "aws s3api get-public-access-block --bucket ${BUCKET_WEB:-none} --query 'PublicAccessBlockConfiguration.RestrictPublicBuckets' --output text"

# ---------- 실제 응답 ----------
check "동적 경로 응답 (ALB → Tomcat)" bash -c \
  "curl -fsS --max-time 25 https://${CF}/ | grep -q APP_INSTANCE"
check_eq "동적 경로 DB 조회 성공" "OK" bash -c \
  "curl -fsS --max-time 25 https://${CF}/ | sed -n 's|.*DB_STATUS</th><td>\([^<]*\).*|\1|p' | head -1"
check "정적 경로 응답 (S3 오리진)" bash -c \
  "curl -fsS --max-time 25 https://${CF}/static/index.html | grep -q '정적 콘텐츠'"

# ---------- 캐시 동작 ----------
# CloudFront 엣지는 여러 서버로 이뤄져 있어 요청마다 다른 엣지에 닿을 수 있다.
# 각 엣지가 개별적으로 캐시를 채우므로 Miss 가 몇 번 더 나오는 것이 정상이다.
# 여러 번 시도해 한 번이라도 Hit 이면 캐시가 동작하는 것이다.
check_eq "정적 경로 캐시 적중" "true" bash -c \
  "hits=0
   for i in \$(seq 1 8); do
     h=\$(curl -sI --max-time 25 https://${CF}/static/style.css | tr -d '\r' | grep -i '^x-cache:' | head -1)
     case \"\$h\" in *Hit*) hits=\$((hits+1)); break ;; esac
     sleep 1
   done
   [ \"\$hits\" -ge 1 ] && echo true || echo 'false(8회 모두 Miss)'"
check_eq "동적 경로는 캐시하지 않음" "true" bash -c \
  "h=\$(curl -sI --max-time 25 https://${CF}/ | tr -d '\r' | grep -i '^x-cache:' | head -1)
   case \"\$h\" in *Miss*|*Error*) echo true ;; *) echo \"false(\$h)\" ;; esac"

# ---------- 보안 ----------
check_eq "HTTP 요청이 HTTPS로 리디렉션" "301" bash -c \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://${CF}/static/index.html"
check_eq "WAF가 공격 패턴 차단" "403" bash -c \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 20 \"https://${CF}/?q=%3Cscript%3Ealert(1)%3C/script%3E\""

# ALB 잠금은 선택 사항이라 적용된 경우에만 확인한다.
if [ "${ALB_LOCKED:-0}" = "1" ]; then
  check_eq "ALB 직접 접근 차단(CloudFront 경유만)" "000" bash -c \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${ALB_DNS:-invalid}/ || echo 000"
else
  log "  (LOCK_ALB=1 로 실행하면 ALB 직접 접근 차단까지 확인합니다)"
fi

check_summary
