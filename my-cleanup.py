#!/bin/sh
''''exec python3 -- "$0" "$@" # '''
# ============================================================
#  my-cleanup.py v2 — 내가 만든 AWS 리소스 찾기 & 정리 도구
# ------------------------------------------------------------
#  위 2줄은 셸/파이썬 겸용 헤더입니다.
#  아래 4가지 실행 방법이 모두 동작합니다.
#
#      python3 my-cleanup.py scan
#      bash    my-cleanup.py scan
#      sh      my-cleanup.py scan
#      ./my-cleanup.py scan          (chmod +x 후)
#
#  ------------------------------------------------------------
#  소유자 판별 (두 경로의 합집합)
#    1) 태그      : Owner=<내 사용자명>
#    2) CloudTrail: 내 사용자명으로 기록된 쓰기 이벤트
#
#  사용 예
#    python3 my-cleanup.py scan                   # 목록 + 옵션 안내
#    python3 my-cleanup.py scan --days 3          # 최근 3일
#    python3 my-cleanup.py scan --regions ap-northeast-2
#    python3 my-cleanup.py delete                 # 계획만 출력
#    python3 my-cleanup.py delete --apply         # 실제 삭제
#    python3 my-cleanup.py delete --apply --select
#
#  스캔은 매번 새로 수행합니다(항상 최신 상태).
#  같은 조건을 반복 조회할 때만 --cache 로 직전 결과를 재사용하십시오.
#
#  권장 환경: AWS CloudShell (boto3 사전 설치, 자격 증명 자동)
#
#  확인 입력: 삭제 직전 DELETE 를 입력합니다 (영문. 대소문자 무관)
#
#  중단: Ctrl+C 1회 = 안전 중단(진행 중 작업 마무리 후 요약)
#        Ctrl+C 2회 = 즉시 종료
# ============================================================

import sys

if sys.version_info < (3, 7):
    sys.stderr.write("Python 3.7 이상이 필요합니다. 현재: %s\n"
                     % sys.version.split()[0])
    raise SystemExit(1)

import argparse
import json
import os
import re
import signal
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
CACHE_PATH = os.path.join(os.path.expanduser("~"), ".my-cleanup-cache.json")
CACHE_TTL = 900          # 초. 이 시간 안이면 재스캔 없이 재사용


def _install_boto3():
    import subprocess
    sys.stderr.write("boto3 가 없습니다. 설치를 시도합니다...\n")
    for extra in (["--user"], ["--user", "--break-system-packages"], []):
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install",
                                   "--quiet", "boto3"] + extra)
            return True
        except Exception:
            continue
    return False


try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import (ClientError, BotoCoreError,
                                     NoCredentialsError, ProfileNotFound,
                                     EndpointConnectionError)
except ImportError:
    if _install_boto3():
        import boto3
        from botocore.config import Config
        from botocore.exceptions import (ClientError, BotoCoreError,
                                         NoCredentialsError, ProfileNotFound,
                                         EndpointConnectionError)
    else:
        sys.stderr.write("\n설치 실패. 아래 중 하나를 실행하십시오.\n"
                         "  pip3 install boto3 --user\n"
                         "  또는 AWS CloudShell 에서 실행 (boto3 기본 제공)\n")
        raise SystemExit(1)


# ============================================================
#  설정
# ============================================================
DEFAULT_REGIONS = ["ap-northeast-2", "us-west-2", "us-east-1"]

BOTO_CFG = Config(
    retries={"max_attempts": 10, "mode": "adaptive"},
    connect_timeout=15,
    read_timeout=70,
)

REGION_DEAD = {
    "AuthFailure", "UnrecognizedClientException", "InvalidClientTokenId",
    "OptInRequired", "SubscriptionRequiredException", "AccessDenied",
    "AccessDeniedException", "UnauthorizedOperation",
}

GONE = {
    "InvalidInstanceID.NotFound", "InvalidVolume.NotFound",
    "InvalidSnapshot.NotFound", "InvalidAllocationID.NotFound",
    "InvalidNatGatewayID.NotFound", "InvalidVpcID.NotFound",
    "InvalidSubnetID.NotFound", "InvalidGroup.NotFound",
    "InvalidRouteTableID.NotFound", "InvalidInternetGatewayID.NotFound",
    "InvalidNetworkInterfaceID.NotFound", "InvalidVpcEndpointId.NotFound",
    "InvalidAMIID.NotFound", "InvalidAMIID.Unavailable",
    "NotFoundException", "ResourceNotFoundException", "ResourceNotFound",
    "NoSuchEntity", "NoSuchBucket", "NoSuchKey", "ValidationError",
    "DBInstanceNotFound", "DBClusterNotFoundFault", "404",
    "LoadBalancerNotFound", "TargetGroupNotFound",
    "CacheClusterNotFound", "FileSystemNotFound",
    "AWS.SimpleQueueService.NonExistentQueue",
}

RETRYABLE = {
    "DependencyViolation", "ResourceInUseException", "InvalidGroup.InUse",
    "InvalidParameterCombination", "InvalidDBInstanceState",
    "InvalidDBClusterStateFault", "InvalidCacheClusterState",
    "OperationNotPermitted", "IncorrectState", "InUseException",
    "ResourceConflictException", "InvalidNetworkInterface.InUse",
    "ThrottlingException", "Throttling", "RequestLimitExceeded",
    "TooManyRequestsException", "InvalidStateException", "ClusterNotFound",
    "ConcurrentModificationException", "InvalidParameterValue",
}

BILLABLE = {
    "cloudformation:stack", "autoscaling:autoScalingGroup",
    "elasticloadbalancing:loadbalancer", "elasticloadbalancing:targetgroup",
    "ec2:instance", "ec2:natgateway", "ec2:elastic-ip", "ec2:volume",
    "ec2:snapshot", "ec2:image", "ec2:vpc-endpoint",
    "rds:db", "rds:cluster", "elasticache:cluster",
    "eks:cluster", "eks:nodegroup", "ecs:cluster", "ecs:service",
    "lambda:function", "apigateway:restapi", "apigateway:api",
    "s3:bucket", "dynamodb:table", "elasticfilesystem:file-system",
    "secretsmanager:secret", "logs:log-group", "cloudwatch:alarm",
    "sns:topic", "sqs:queue", "states:stateMachine",
}

NETWORK = {
    "ec2:network-interface", "ec2:security-group", "ec2:subnet",
    "ec2:route-table", "ec2:internet-gateway", "ec2:vpc",
}

DELETE_ORDER = [
    "cloudformation:stack",
    "eks:nodegroup", "eks:cluster",
    "ecs:service", "ecs:cluster",
    "autoscaling:autoScalingGroup",
    "elasticloadbalancing:loadbalancer",
    "elasticloadbalancing:targetgroup",
    "ec2:instance",
    "rds:db", "rds:cluster",
    "elasticache:cluster",
    "ec2:natgateway",
    "ec2:elastic-ip",
    "elasticfilesystem:file-system",
    "lambda:function",
    "apigateway:restapi", "apigateway:api",
    "dynamodb:table",
    "s3:bucket",
    "secretsmanager:secret",
    "states:stateMachine",
    "sns:topic", "sqs:queue",
    "cloudwatch:alarm", "logs:log-group",
    "ec2:volume", "ec2:snapshot", "ec2:image",
    "ec2:vpc-endpoint",
    "ec2:network-interface", "ec2:security-group",
    "ec2:subnet", "ec2:route-table", "ec2:internet-gateway", "ec2:vpc",
]

ID_PATTERNS = {
    "ec2:instance":          re.compile(r"\bi-[0-9a-f]{8,17}\b"),
    "ec2:volume":            re.compile(r"\bvol-[0-9a-f]{8,17}\b"),
    "ec2:snapshot":          re.compile(r"\bsnap-[0-9a-f]{8,17}\b"),
    "ec2:image":             re.compile(r"\bami-[0-9a-f]{8,17}\b"),
    "ec2:natgateway":        re.compile(r"\bnat-[0-9a-f]{8,17}\b"),
    "ec2:elastic-ip":        re.compile(r"\beipalloc-[0-9a-f]{8,17}\b"),
    "ec2:security-group":    re.compile(r"\bsg-[0-9a-f]{8,17}\b"),
    "ec2:subnet":            re.compile(r"\bsubnet-[0-9a-f]{8,17}\b"),
    "ec2:vpc":               re.compile(r"\bvpc-[0-9a-f]{8,17}\b"),
    "ec2:route-table":       re.compile(r"\brtb-[0-9a-f]{8,17}\b"),
    "ec2:internet-gateway":  re.compile(r"\bigw-[0-9a-f]{8,17}\b"),
    "ec2:network-interface": re.compile(r"\beni-[0-9a-f]{8,17}\b"),
    "ec2:vpc-endpoint":      re.compile(r"\bvpce-[0-9a-f]{8,17}\b"),
}

CT_TYPE_MAP = {
    "AWS::EC2::Instance": "ec2:instance",
    "AWS::EC2::Volume": "ec2:volume",
    "AWS::EC2::Snapshot": "ec2:snapshot",
    "AWS::EC2::NatGateway": "ec2:natgateway",
    "AWS::EC2::SecurityGroup": "ec2:security-group",
    "AWS::EC2::Subnet": "ec2:subnet",
    "AWS::EC2::VPC": "ec2:vpc",
    "AWS::EC2::RouteTable": "ec2:route-table",
    "AWS::EC2::InternetGateway": "ec2:internet-gateway",
    "AWS::RDS::DBInstance": "rds:db",
    "AWS::RDS::DBCluster": "rds:cluster",
    "AWS::S3::Bucket": "s3:bucket",
    "AWS::Lambda::Function": "lambda:function",
    "AWS::DynamoDB::Table": "dynamodb:table",
    "AWS::CloudFormation::Stack": "cloudformation:stack",
    "AWS::SNS::Topic": "sns:topic",
    "AWS::SQS::Queue": "sqs:queue",
    "AWS::ElasticLoadBalancingV2::LoadBalancer": "elasticloadbalancing:loadbalancer",
    "AWS::EKS::Cluster": "eks:cluster",
    "AWS::ECS::Cluster": "ecs:cluster",
    "AWS::SecretsManager::Secret": "secretsmanager:secret",
    "AWS::StepFunctions::StateMachine": "states:stateMachine",
    "AWS::ElasticLoadBalancingV2::TargetGroup":
        "elasticloadbalancing:targetgroup",
    "AWS::ElastiCache::CacheCluster": "elasticache:cluster",
}

SKIP_ARN_SERVICES = {"iam", "sts", "organizations", "health", "support",
                     "servicequotas", "ce", "budgets", "cloudtrail",
                     "signin", "access-analyzer"}

# CloudTrail 이벤트에는 ARN 이 없고 이름 필드만 있는 경우가 많습니다.
# (예: CreateBucket -> requestParameters.bucketName)
JSON_KEY_PATTERNS = [
    (re.compile(r'"bucketName"\s*:\s*"([^"]{3,63})"'), "s3:bucket"),
    (re.compile(r'"functionName"\s*:\s*"([^"]+)"'), "lambda:function"),
    (re.compile(r'"tableName"\s*:\s*"([^"]+)"'), "dynamodb:table"),
    (re.compile(r'"dBInstanceIdentifier"\s*:\s*"([^"]+)"'), "rds:db"),
    (re.compile(r'"dBClusterIdentifier"\s*:\s*"([^"]+)"'), "rds:cluster"),
    (re.compile(r'"stackName"\s*:\s*"([^"]+)"'), "cloudformation:stack"),
    (re.compile(r'"logGroupName"\s*:\s*"([^"]+)"'), "logs:log-group"),
    (re.compile(r'"autoScalingGroupName"\s*:\s*"([^"]+)"'),
     "autoscaling:autoScalingGroup"),
    (re.compile(r'"cacheClusterId"\s*:\s*"([^"]+)"'), "elasticache:cluster"),
    (re.compile(r'"fileSystemId"\s*:\s*"(fs-[^"]+)"'),
     "elasticfilesystem:file-system"),
    (re.compile(r'"restApiId"\s*:\s*"([a-z0-9]{10})"'), "apigateway:restapi"),
    (re.compile(r'"apiId"\s*:\s*"([a-z0-9]{10})"'), "apigateway:api"),
    # SQS 는 CreateQueue 응답에 ARN 이 없고 queueUrl 만 있습니다.
    (re.compile(r'"queueName"\s*:\s*"([^"]+)"'), "sqs:queue"),
    (re.compile(r'"queueUrl"\s*:\s*"https?://[^"]*/([^"/]+)"'), "sqs:queue"),
    (re.compile(r'"QueueName"\s*:\s*"([^"]+)"'), "sqs:queue"),
    (re.compile(r'"topicArn"\s*:\s*"arn:[^"]*:([^":]+)"'), "sns:topic"),
    (re.compile(r'"secretId"\s*:\s*"([^"]+)"'), "secretsmanager:secret"),
    (re.compile(r'"stateMachineArn"\s*:\s*"arn:[^"]*:([^":]+)"'),
     "states:stateMachine"),
]

# 이름 재사용 제한(48~72h) 때문에 유지하고 싶은 버킷 이름을 넣으십시오.
KEEP_BUCKETS = set()


# ============================================================
#  중단 처리
# ============================================================
class Stopper:
    def __init__(self):
        self.requested = False
        self._hits = 0

    def handle(self, signum, frame):
        self._hits += 1
        if self._hits >= 2:
            sys.stderr.write("\n즉시 종료합니다.\n")
            sys.stderr.flush()
            os._exit(130)
        self.requested = True
        sys.stderr.write(
            "\n중단 요청됨 — 진행 중인 작업을 마치고 요약을 출력합니다.\n"
            "(한 번 더 누르면 즉시 종료)\n")
        sys.stderr.flush()

    def sleep(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            if self.requested:
                return False
            time.sleep(0.2)
        return True


STOP = Stopper()


# ============================================================
#  출력 유틸
# ============================================================
USE_COLOR = (sys.stdout.isatty()
             and os.environ.get("NO_COLOR") is None
             and os.environ.get("TERM", "") != "dumb")


def c(text, color):
    if not USE_COLOR:
        return str(text)
    codes = {"r": 31, "g": 32, "y": 33, "b": 36, "d": 90}
    return "\033[%dm%s\033[0m" % (codes.get(color, 0), text)


def warn(t):
    return c(t, "y")


def clip(s, n):
    s = str(s)
    return s if len(s) <= n else s[:n - 1] + "…"


def client(session, svc, region=None):
    return session.client(svc, region_name=region, config=BOTO_CFG)


def err_code(e):
    try:
        return e.response["Error"]["Code"]
    except Exception:
        return type(e).__name__


def err_msg(e):
    try:
        return e.response["Error"].get("Message", "")
    except Exception:
        return str(e)


# ============================================================
#  신원 확인
# ============================================================
def whoami(session):
    ident = client(session, "sts").get_caller_identity()
    arn = ident["Arn"]
    if ":user/" in arn:
        return ident["Account"], arn.split(":user/")[-1].split("/")[-1], "IAM 사용자", arn
    if ":assumed-role/" in arn:
        return ident["Account"], arn.split(":assumed-role/")[-1].split("/")[0], "역할", arn
    return ident["Account"], arn.rsplit("/", 1)[-1], "기타", arn


# ============================================================
#  발견 저장소
# ============================================================
class Found:
    def __init__(self):
        self._d = {}
        self._lock = threading.Lock()

    def add(self, region, rtype, rid, source):
        if not rid or not rtype:
            return
        key = (region, rtype, str(rid))
        with self._lock:
            self._d.setdefault(key, set()).add(source)

    def items(self):
        for (region, rtype, rid), src in self._d.items():
            yield region, rtype, rid, ",".join(sorted(src))

    def drop(self, region, rtype, rid):
        with self._lock:
            self._d.pop((region, rtype, rid), None)

    def source_stats(self):
        stat = defaultdict(int)
        for src in self._d.values():
            for s in src:
                stat[s] += 1
        return dict(stat)

    def load_rows(self, rows):
        for region, rtype, rid, src in rows:
            for s in str(src).split(","):
                self.add(region, rtype, rid, s)

    def __len__(self):
        return len(self._d)


def parse_arn(arn, account):
    arn = arn.rstrip('"\',.;)}]')
    parts = arn.split(":", 5)
    if len(parts) < 6 or parts[0] != "arn":
        return None
    service, region, acct, tail = parts[2], parts[3], parts[4], parts[5]
    if service in SKIP_ARN_SERVICES:
        return None
    if acct and acct != account:
        return None
    if "/" in tail:
        kind, rid = tail.split("/", 1)
    elif ":" in tail:
        kind, rid = tail.split(":", 1)
    else:
        kind = {"s3": "bucket", "sns": "topic", "sqs": "queue"}.get(service, "")
        rid = tail
    if not rid:
        return None
    rtype = "%s:%s" % (service, kind) if kind else service
    return (region or "global"), rtype, rid


# ============================================================
#  탐색 1: 태그
# ============================================================
def discover_by_tag(session, region, owner, account, found, tag_key):
    try:
        cli = client(session, "resourcegroupstaggingapi", region)
        for page in cli.get_paginator("get_resources").paginate(
                TagFilters=[{"Key": tag_key, "Values": [owner]}],
                ResourcesPerPage=100):
            if STOP.requested:
                return "중단"
            for r in page.get("ResourceTagMappingList", []):
                parsed = parse_arn(r["ResourceARN"], account)
                if parsed:
                    reg = region if parsed[0] == "global" else parsed[0]
                    found.add(reg, parsed[1], parsed[2], "tag")
        return None
    except ClientError as e:
        code = err_code(e)
        return None if code in REGION_DEAD else "태그 조회 실패(%s)" % code
    except EndpointConnectionError:
        return None
    except BotoCoreError as e:
        return "태그 조회 오류(%s)" % type(e).__name__
    except Exception as e:                                   # noqa: BLE001
        return "태그 조회 예외(%s)" % clip(e, 40)


# ============================================================
#  탐색 2: CloudTrail
# ============================================================
ARN_RE = re.compile(r"arn:aws[a-z\-]*:[^\"\\\s,\]}]+")
READ_PREFIX = ("Describe", "List", "Get", "Lookup", "Head", "Query", "Scan",
               "BatchGet", "Search", "Preview", "Check", "Validate", "Assume")


def discover_by_cloudtrail(session, region, owner, account, found, since):
    seen = 0
    try:
        cli = client(session, "cloudtrail", region)
        pages = cli.get_paginator("lookup_events").paginate(
            LookupAttributes=[{"AttributeKey": "Username",
                               "AttributeValue": owner}],
            StartTime=since,
            EndTime=datetime.now(timezone.utc),
            PaginationConfig={"MaxItems": 3000, "PageSize": 50},
        )
        for page in pages:
            if STOP.requested:
                return seen, "중단"
            for ev in page.get("Events") or []:
                seen += 1
                if str(ev.get("EventName", "")).startswith(READ_PREFIX):
                    continue
                raw_peek = ev.get("CloudTrailEvent") or ""
                # 실패한 API 호출은 리소스를 만들지 않았으므로 제외
                if '"errorCode"' in raw_peek:
                    continue
                for res in ev.get("Resources") or []:
                    rt = CT_TYPE_MAP.get(res.get("ResourceType") or "")
                    rn = res.get("ResourceName")
                    if rt and rn:
                        found.add(region, rt, rn, "trail")
                raw = ev.get("CloudTrailEvent") or ""
                if not raw:
                    continue
                for m in ARN_RE.findall(raw):
                    parsed = parse_arn(m, account)
                    if parsed and parsed[1] in (BILLABLE | NETWORK):
                        reg = region if parsed[0] == "global" else parsed[0]
                        found.add(reg, parsed[1], parsed[2], "trail")
                for rtype, pat in ID_PATTERNS.items():
                    for rid in set(pat.findall(raw)):
                        found.add(region, rtype, rid, "trail")
                for pat, rtype in JSON_KEY_PATTERNS:
                    for rid in set(pat.findall(raw)):
                        if rid.startswith("arn:"):
                            rid = rid.split(":")[-1].split("/")[-1]
                        found.add(region, rtype, rid, "trail")
            if not STOP.sleep(0.15):        # LookupEvents 초당 2회 제한
                return seen, "중단"
        return seen, None
    except ClientError as e:
        code = err_code(e)
        if code in REGION_DEAD:
            return seen, None
        return seen, "CloudTrail 조회 실패(%s)" % code
    except EndpointConnectionError:
        return seen, None
    except BotoCoreError as e:
        return seen, "CloudTrail 오류(%s)" % type(e).__name__
    except Exception as e:                                   # noqa: BLE001
        return seen, "CloudTrail 예외(%s)" % clip(e, 40)


# ============================================================
#  존재 확인 — 실제로 살아 있는 리소스만 남긴다
# ------------------------------------------------------------
#  CloudTrail 에는 "삭제" 이벤트도 남습니다. 그래서 어제 지운 리소스도
#  다음 scan 에서 다시 발견됩니다. 이를 막기 위해 리소스 타입별로
#  "지금 실제로 존재하는 ID 집합"을 조회해 대조합니다.
#
#  live_set() 이 None 을 반환하면 (권한 부족 등) 판단 불가로 보고
#  목록에 그대로 남겨 둡니다. 지워지지 않은 것을 놓치는 쪽보다
#  이미 지운 것을 한 번 더 보여주는 쪽이 안전하기 때문입니다.
# ============================================================
def _norm(rtype, rid):
    """저장된 식별자를 조회 결과와 비교 가능한 형태로 정규화."""
    rid = str(rid)
    if rtype == "s3:bucket":
        return rid.split(":::")[-1]
    if rtype == "logs:log-group":
        return rid.split(":log-group:")[-1].rstrip("*").rstrip(":")
    if rtype == "lambda:function":
        return rid.split(":function:")[-1].split(":")[0]
    if rtype == "elasticloadbalancing:loadbalancer":
        return rid.split(":loadbalancer/")[-1]
    if rtype == "elasticloadbalancing:targetgroup":
        return rid.split(":targetgroup/")[-1]
    if rtype == "cloudformation:stack":
        parts = [p for p in rid.split("/") if p]
        return parts[-2] if len(parts) >= 2 else parts[-1]
    if rtype == "states:stateMachine":
        return rid.split(":")[-1]
    if rtype == "sns:topic":
        # 저장은 이름, 조회 결과는 ARN 이므로 항상 이름으로 통일
        return rid.split(":")[-1]
    if rtype == "secretsmanager:secret":
        # 시크릿 ARN 은 이름 뒤에 임의 6자가 붙습니다(my-secret-AbC123).
        # 접미사를 추측해 잘라내면 'kkk-secret' 같은 이름이 훼손되므로,
        # 여기서는 자르지 않고 live_set 이 두 형태를 모두 제공합니다.
        return rid.split(":")[-1].split("/")[-1]
    if rtype in ("rds:db", "rds:cluster", "elasticache:cluster",
                 "cloudwatch:alarm"):
        return rid.split(":")[-1]
    if rtype in ("dynamodb:table", "autoscaling:autoScalingGroup",
                 "apigateway:restapi", "apigateway:api", "eks:cluster",
                 "ecs:cluster", "sqs:queue", "elasticfilesystem:file-system"):
        return rid.split("/")[-1].split(":")[-1]
    return rid


def _pages(client_obj, op, key, **kw):
    """페이지네이션 지원 여부와 무관하게 결과 리스트를 모은다."""
    out = []
    try:
        pag = client_obj.get_paginator(op)
        for page in pag.paginate(**kw):
            out.extend(page.get(key) or [])
    except Exception:
        resp = getattr(client_obj, op)(**kw)
        out.extend(resp.get(key) or [])
    return out


def live_set(session, region, rtype):
    """region 에서 rtype 으로 현재 존재하는 식별자 집합. 판단 불가면 None."""
    try:
        if rtype.startswith("ec2:"):
            ec2 = client(session, "ec2", region)
            if rtype == "ec2:instance":
                return {i["InstanceId"]
                        for r in _pages(ec2, "describe_instances", "Reservations")
                        for i in r["Instances"]
                        if i["State"]["Name"] not in ("terminated", "shutting-down")}
            if rtype == "ec2:volume":
                return {v["VolumeId"] for v in _pages(ec2, "describe_volumes", "Volumes")}
            if rtype == "ec2:snapshot":
                return {s["SnapshotId"] for s in
                        _pages(ec2, "describe_snapshots", "Snapshots", OwnerIds=["self"])}
            if rtype == "ec2:image":
                return {i["ImageId"] for i in
                        ec2.describe_images(Owners=["self"]).get("Images") or []}
            if rtype == "ec2:natgateway":
                return {n["NatGatewayId"] for n in
                        _pages(ec2, "describe_nat_gateways", "NatGateways")
                        if n["State"] not in ("deleted", "deleting")}
            if rtype == "ec2:elastic-ip":
                return {a.get("AllocationId") for a in
                        ec2.describe_addresses().get("Addresses") or []
                        if a.get("AllocationId")}
            if rtype == "ec2:security-group":
                return {g["GroupId"] for g in
                        _pages(ec2, "describe_security_groups", "SecurityGroups")}
            if rtype == "ec2:subnet":
                return {s["SubnetId"] for s in _pages(ec2, "describe_subnets", "Subnets")}
            if rtype == "ec2:vpc":
                return {v["VpcId"] for v in _pages(ec2, "describe_vpcs", "Vpcs")}
            if rtype == "ec2:route-table":
                return {r["RouteTableId"] for r in
                        _pages(ec2, "describe_route_tables", "RouteTables")}
            if rtype == "ec2:internet-gateway":
                return {g["InternetGatewayId"] for g in
                        _pages(ec2, "describe_internet_gateways", "InternetGateways")}
            if rtype == "ec2:network-interface":
                return {n["NetworkInterfaceId"] for n in
                        _pages(ec2, "describe_network_interfaces", "NetworkInterfaces")}
            if rtype == "ec2:vpc-endpoint":
                return {e["VpcEndpointId"] for e in
                        _pages(ec2, "describe_vpc_endpoints", "VpcEndpoints")}
            return None

        if rtype == "s3:bucket":
            return {b["Name"] for b in
                    client(session, "s3", region).list_buckets().get("Buckets") or []}
        if rtype == "rds:db":
            return {d["DBInstanceIdentifier"] for d in
                    _pages(client(session, "rds", region),
                           "describe_db_instances", "DBInstances")}
        if rtype == "rds:cluster":
            return {d["DBClusterIdentifier"] for d in
                    _pages(client(session, "rds", region),
                           "describe_db_clusters", "DBClusters")}
        if rtype == "elasticloadbalancing:loadbalancer":
            return {lb["LoadBalancerArn"].split(":loadbalancer/")[-1] for lb in
                    _pages(client(session, "elbv2", region),
                           "describe_load_balancers", "LoadBalancers")}
        if rtype == "elasticloadbalancing:targetgroup":
            return {tg["TargetGroupArn"].split(":targetgroup/")[-1] for tg in
                    _pages(client(session, "elbv2", region),
                           "describe_target_groups", "TargetGroups")}
        if rtype == "autoscaling:autoScalingGroup":
            return {g["AutoScalingGroupName"] for g in
                    _pages(client(session, "autoscaling", region),
                           "describe_auto_scaling_groups", "AutoScalingGroups")}
        if rtype == "lambda:function":
            return {f["FunctionName"] for f in
                    _pages(client(session, "lambda", region),
                           "list_functions", "Functions")}
        if rtype == "dynamodb:table":
            return set(_pages(client(session, "dynamodb", region),
                              "list_tables", "TableNames"))
        if rtype == "logs:log-group":
            return {g["logGroupName"] for g in
                    _pages(client(session, "logs", region),
                           "describe_log_groups", "logGroups")}
        if rtype == "cloudwatch:alarm":
            return {a["AlarmName"] for a in
                    _pages(client(session, "cloudwatch", region),
                           "describe_alarms", "MetricAlarms")}
        if rtype == "sns:topic":
            return {t["TopicArn"] for t in
                    _pages(client(session, "sns", region), "list_topics", "Topics")}
        if rtype == "sqs:queue":
            urls = client(session, "sqs", region).list_queues().get("QueueUrls") or []
            return {u.split("/")[-1] for u in urls}
        if rtype == "cloudformation:stack":
            return {s["StackName"] for s in
                    _pages(client(session, "cloudformation", region),
                           "describe_stacks", "Stacks")
                    if s["StackStatus"] != "DELETE_COMPLETE"}
        if rtype == "elasticfilesystem:file-system":
            return {f["FileSystemId"] for f in
                    _pages(client(session, "efs", region),
                           "describe_file_systems", "FileSystems")}
        if rtype == "secretsmanager:secret":
            out = set()
            for sec in _pages(client(session, "secretsmanager", region),
                              "list_secrets", "SecretList"):
                if sec.get("Name"):
                    out.add(sec["Name"])                     # my-secret
                if sec.get("ARN"):
                    out.add(sec["ARN"].split(":")[-1])       # my-secret-AbC123
            return out
        if rtype == "eks:cluster":
            return set(_pages(client(session, "eks", region),
                              "list_clusters", "clusters"))
        if rtype == "ecs:cluster":
            arns = _pages(client(session, "ecs", region), "list_clusters",
                          "clusterArns")
            return {a.split("/")[-1] for a in arns}
        if rtype == "elasticache:cluster":
            return {c_["CacheClusterId"] for c_ in
                    _pages(client(session, "elasticache", region),
                           "describe_cache_clusters", "CacheClusters")}
        if rtype == "states:stateMachine":
            return {m["name"] for m in
                    _pages(client(session, "stepfunctions", region),
                           "list_state_machines", "stateMachines")}
        if rtype == "apigateway:restapi":
            return {a["id"] for a in
                    _pages(client(session, "apigateway", region),
                           "get_rest_apis", "items")}
        if rtype == "apigateway:api":
            return {a["ApiId"] for a in
                    client(session, "apigatewayv2", region)
                    .get_apis().get("Items") or []}
        return None
    except ClientError:
        return None
    except EndpointConnectionError:
        return None
    except Exception:                                        # noqa: BLE001
        return None


def prune_missing(session, found, verbose=False, show_items=False):
    """이미 삭제된 리소스를 목록에서 제거."""
    buckets = defaultdict(lambda: defaultdict(list))
    for region, rtype, rid, _ in list(found.items()):
        buckets[region][rtype].append(rid)

    removed = 0
    dropped = []
    unknown = set()
    for region, types in buckets.items():
        if STOP.requested:
            break
        for rtype, ids in types.items():
            if STOP.requested:
                break
            alive = live_set(session, region, rtype)
            if alive is None:
                unknown.add(rtype)
                continue
            alive_norm = {_norm(rtype, a) for a in alive}
            for rid in ids:
                if _norm(rtype, rid) not in alive_norm:
                    found.drop(region, rtype, rid)
                    dropped.append((region, rtype, rid))
                    removed += 1
    if verbose:
        print("    이미 삭제된 %d건을 목록에서 제외%s"
              % (removed, "" if show_items or not removed else " (-v 로 상세)"))
        if show_items:
            for region, rtype, rid in dropped:
                print(c("      · %s %s %s" % (region, rtype, clip(rid, 40)), "d"))
        if unknown:
            print(warn("    확인 불가 타입(그대로 표시): %s"
                       % ", ".join(sorted(unknown))))
    return removed


# ============================================================
#  삭제
# ============================================================
def delete_bucket(session, bucket):
    name = bucket.split(":::")[-1] if ":::" in bucket else bucket
    try:
        s3 = session.resource("s3", config=BOTO_CFG)
        b = s3.Bucket(name)
        b.object_versions.delete()
        b.objects.delete()
        if name in KEEP_BUCKETS:
            return "ok", "내용만 삭제 (버킷 유지)"
        b.delete()
        return "ok", "삭제 완료"
    except ClientError as e:
        code = err_code(e)
        if code in GONE:
            return "ok", "이미 없음"
        if code in RETRYABLE:
            return "retry", code
        return "fail", code
    except Exception as e:                                   # noqa: BLE001
        return "fail", clip(e, 80)


def delete_one(session, region, rtype, rid):
    """반환 (status, message). status: ok | retry | fail"""
    def s(svc):
        return client(session, svc, region)

    try:
        if rtype == "cloudformation:stack":
            name = rid.split("/")[-2] if rid.count("/") >= 2 else rid.split("/")[-1]
            s("cloudformation").delete_stack(StackName=name)
        elif rtype == "autoscaling:autoScalingGroup":
            s("autoscaling").delete_auto_scaling_group(
                AutoScalingGroupName=rid.split("/")[-1], ForceDelete=True)
        elif rtype == "ec2:instance":
            ec2 = s("ec2")
            try:
                ec2.modify_instance_attribute(
                    InstanceId=rid, DisableApiTermination={"Value": False})
            except ClientError:
                pass
            ec2.terminate_instances(InstanceIds=[rid])
        elif rtype == "elasticloadbalancing:loadbalancer":
            elb = s("elbv2")
            arn = rid if rid.startswith("arn:") else None
            if arn is None:
                for lb in elb.describe_load_balancers()["LoadBalancers"]:
                    if lb["LoadBalancerArn"].endswith(rid):
                        arn = lb["LoadBalancerArn"]
                        break
            if not arn:
                return "ok", "이미 없음"
            try:
                elb.modify_load_balancer_attributes(
                    LoadBalancerArn=arn,
                    Attributes=[{"Key": "deletion_protection.enabled",
                                 "Value": "false"}])
            except ClientError:
                pass
            elb.delete_load_balancer(LoadBalancerArn=arn)
        elif rtype == "elasticloadbalancing:targetgroup":
            if not rid.startswith("arn:"):
                return "ok", "ARN 없음 - 건너뜀"
            s("elbv2").delete_target_group(TargetGroupArn=rid)
        elif rtype == "rds:db":
            rds = s("rds")
            name = rid.split(":")[-1]
            try:
                rds.modify_db_instance(DBInstanceIdentifier=name,
                                       DeletionProtection=False,
                                       ApplyImmediately=True)
            except ClientError:
                pass
            rds.delete_db_instance(DBInstanceIdentifier=name,
                                   SkipFinalSnapshot=True,
                                   DeleteAutomatedBackups=True)
        elif rtype == "rds:cluster":
            rds = s("rds")
            name = rid.split(":")[-1]
            try:
                rds.modify_db_cluster(DBClusterIdentifier=name,
                                      DeletionProtection=False,
                                      ApplyImmediately=True)
            except ClientError:
                pass
            rds.delete_db_cluster(DBClusterIdentifier=name,
                                  SkipFinalSnapshot=True)
        elif rtype == "ec2:natgateway":
            s("ec2").delete_nat_gateway(NatGatewayId=rid)
        elif rtype == "ec2:elastic-ip":
            s("ec2").release_address(AllocationId=rid)
        elif rtype == "ec2:volume":
            s("ec2").delete_volume(VolumeId=rid)
        elif rtype == "ec2:snapshot":
            s("ec2").delete_snapshot(SnapshotId=rid)
        elif rtype == "ec2:image":
            s("ec2").deregister_image(ImageId=rid)
        elif rtype == "ec2:vpc-endpoint":
            s("ec2").delete_vpc_endpoints(VpcEndpointIds=[rid])
        elif rtype == "lambda:function":
            s("lambda").delete_function(FunctionName=rid.split(":function:")[-1])
        elif rtype == "apigateway:restapi":
            s("apigateway").delete_rest_api(restApiId=rid.split("/")[-1])
        elif rtype == "apigateway:api":
            s("apigatewayv2").delete_api(ApiId=rid.split("/")[-1])
        elif rtype == "dynamodb:table":
            s("dynamodb").delete_table(TableName=rid.split("/")[-1])
        elif rtype == "s3:bucket":
            return delete_bucket(session, rid)
        elif rtype == "elasticfilesystem:file-system":
            efs = s("efs")
            fsid = rid.split("/")[-1]
            for mt in efs.describe_mount_targets(
                    FileSystemId=fsid).get("MountTargets") or []:
                try:
                    efs.delete_mount_target(MountTargetId=mt["MountTargetId"])
                except ClientError:
                    pass
            efs.delete_file_system(FileSystemId=fsid)
        elif rtype == "secretsmanager:secret":
            s("secretsmanager").delete_secret(SecretId=rid,
                                              ForceDeleteWithoutRecovery=True)
        elif rtype == "sns:topic":
            sns = s("sns")
            arn = rid if rid.startswith("arn:") else None
            if arn is None:
                # 발견 단계에서는 이름만 저장되므로 ARN 을 조회해 찾습니다.
                for t in _pages(sns, "list_topics", "Topics"):
                    if t["TopicArn"].split(":")[-1] == rid.split(":")[-1]:
                        arn = t["TopicArn"]
                        break
            if not arn:
                return "ok", "이미 없음"
            sns.delete_topic(TopicArn=arn)
        elif rtype == "states:stateMachine":
            sfn = s("stepfunctions")
            arn = rid if rid.startswith("arn:") else None
            if arn is None:
                for m in _pages(sfn, "list_state_machines", "stateMachines"):
                    if m["name"] == rid.split(":")[-1]:
                        arn = m["stateMachineArn"]
                        break
            if not arn:
                return "ok", "이미 없음"
            sfn.delete_state_machine(stateMachineArn=arn)
        elif rtype == "sqs:queue":
            sqs = s("sqs")
            url = sqs.get_queue_url(QueueName=rid.split("/")[-1])["QueueUrl"]
            sqs.delete_queue(QueueUrl=url)
        elif rtype == "logs:log-group":
            name = rid.split(":log-group:")[-1].rstrip("*").rstrip(":")
            s("logs").delete_log_group(logGroupName=name)
        elif rtype == "cloudwatch:alarm":
            s("cloudwatch").delete_alarms(AlarmNames=[rid.split(":")[-1]])
        elif rtype == "eks:nodegroup":
            parts = [p for p in rid.split("/") if p]
            if len(parts) < 2:
                return "fail", "노드그룹 경로 파싱 불가"
            s("eks").delete_nodegroup(clusterName=parts[-2],
                                      nodegroupName=parts[-1])
        elif rtype == "eks:cluster":
            s("eks").delete_cluster(name=rid.split("/")[-1])
        elif rtype == "ecs:service":
            parts = [p for p in rid.split("/") if p]
            if len(parts) < 2:
                return "fail", "서비스 경로 파싱 불가"
            s("ecs").delete_service(cluster=parts[-2], service=parts[-1],
                                    force=True)
        elif rtype == "ecs:cluster":
            s("ecs").delete_cluster(cluster=rid.split("/")[-1])
        elif rtype == "elasticache:cluster":
            s("elasticache").delete_cache_cluster(
                CacheClusterId=rid.split(":")[-1])
        elif rtype == "ec2:network-interface":
            s("ec2").delete_network_interface(NetworkInterfaceId=rid)
        elif rtype == "ec2:security-group":
            s("ec2").delete_security_group(GroupId=rid)
        elif rtype == "ec2:subnet":
            s("ec2").delete_subnet(SubnetId=rid)
        elif rtype == "ec2:route-table":
            s("ec2").delete_route_table(RouteTableId=rid)
        elif rtype == "ec2:internet-gateway":
            ec2 = s("ec2")
            info = ec2.describe_internet_gateways(InternetGatewayIds=[rid])
            for att in info["InternetGateways"][0].get("Attachments") or []:
                try:
                    ec2.detach_internet_gateway(InternetGatewayId=rid,
                                                VpcId=att["VpcId"])
                except ClientError:
                    pass
            ec2.delete_internet_gateway(InternetGatewayId=rid)
        elif rtype == "ec2:vpc":
            s("ec2").delete_vpc(VpcId=rid)
        else:
            return "fail", "미지원 타입 - 콘솔에서 수동 삭제"
        return "ok", "삭제 요청 완료"

    except ClientError as e:
        code = err_code(e)
        if code in GONE:
            return "ok", "이미 없음"
        if code in RETRYABLE:
            return "retry", "대기 (%s)" % code
        if code in REGION_DEAD:
            return "fail", "권한 없음 (%s)" % code
        return "fail", "%s: %s" % (code, clip(err_msg(e), 60))
    except EndpointConnectionError:
        return "retry", "네트워크 연결 실패"
    except BotoCoreError as e:
        return "retry", "일시 오류(%s)" % type(e).__name__
    except Exception as e:                                   # noqa: BLE001
        return "fail", clip(e, 90)


# ============================================================
#  메인
# ============================================================
def build_parser():
    p = argparse.ArgumentParser(
        prog="my-cleanup.py",
        description="내가 만든 AWS 리소스 찾기 & 정리",
        epilog="실행 예:  python3 my-cleanup.py scan")
    p.add_argument("command", choices=["scan", "delete"], nargs="?",
                   default="scan")
    p.add_argument("--profile", help="AWS CLI 프로파일")
    p.add_argument("--owner", help="소유자 이름 (기본: 현재 IAM 사용자)")
    p.add_argument("--tag-key", default="Owner", help="소유자 태그 키 (기본 Owner)")
    p.add_argument("--regions", help="쉼표 구분 리전 목록")
    p.add_argument("--all-regions", action="store_true", help="전 리전 (느림)")
    p.add_argument("--since", help="탐색 시작일 YYYY-MM-DD (UTC)")
    p.add_argument("--days", type=int, default=0, help="최근 N일 (1~90)")
    p.add_argument("--include-network", action="store_true",
                   help="VPC/서브넷/SG 등 무과금 네트워크도 삭제")
    g = p.add_argument_group("삭제 대상 선택")
    g.add_argument("--select", action="store_true",
                   help="목록을 보고 번호로 개별 선택 (대화형)")
    g.add_argument("--pick", metavar="SPEC",
                   help="번호 지정: '1,3,5-8' | all | none")
    g.add_argument("--only", metavar="TYPES",
                   help="해당 타입만: 'ec2:instance,s3:bucket' 또는 'ec2'")
    g.add_argument("--exclude", metavar="TYPES",
                   help="해당 타입 제외: 's3:bucket,ec2:snapshot'")
    g.add_argument("--confirm-each", action="store_true",
                   help="리소스마다 y/n 개별 확인 후 삭제")
    p.add_argument("--apply", action="store_true", help="실제 삭제 실행")
    p.add_argument("--yes", action="store_true", help="확인 질문 생략")
    p.add_argument("--passes", type=int, default=3, help="삭제 반복 (기본 3)")
    p.add_argument("--verify", action="store_true",
                   help="삭제 후 실제로 사라졌는지 재확인")
    p.add_argument("--cache", action="store_true",
                   help="직전 스캔 결과 재사용 (15분 이내, 빠름). "
                        "기본은 항상 새로 스캔합니다")
    p.add_argument("--no-cache", action="store_true",
                   help=argparse.SUPPRESS)   # 기본 동작. 하위 호환용으로만 허용
    p.add_argument("-v", "--verbose", action="store_true",
                   help="이미 삭제된 항목 등 상세 표시")
    p.add_argument("--no-color", action="store_true", help="색상 끄기")
    return p


def resolve_since(args):
    if args.since:
        try:
            return datetime.strptime(args.since, "%Y-%m-%d").replace(
                tzinfo=timezone.utc)
        except ValueError:
            raise SystemExit("--since 형식 오류: YYYY-MM-DD 로 입력하십시오.")
    if args.days:
        if args.days < 1 or args.days > 90:
            raise SystemExit("--days 는 1~90 이어야 합니다 (CloudTrail 보관 90일).")
        return datetime.now(timezone.utc) - timedelta(days=args.days)
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0,
                                              microsecond=0)


def split_csv(value):
    return [v.strip() for v in (value or "").split(",") if v.strip()]


def matches_any(rtype, patterns):
    """'ec2:instance' 정확 일치, 'ec2' 접두사 일치, 'ec2:*' 와일드카드 지원."""
    for p in patterns:
        p = p.strip().lower()
        t = rtype.lower()
        if p.endswith("*"):
            if t.startswith(p[:-1]):
                return True
        elif t == p or t.startswith(p + ":"):
            return True
    return False


def parse_pick(spec, total):
    """'1,3,5-8' / 'all' / 'none' -> 1-based 인덱스 집합. 오류면 None."""
    spec = (spec or "").strip().lower()
    if spec in ("all", "a", "*"):
        return set(range(1, total + 1))
    if spec in ("none", "n", ""):
        return set()
    picked = set()
    for part in spec.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            try:
                lo, hi = part.split("-", 1)
                lo, hi = int(lo), int(hi)
            except ValueError:
                print(warn("범위 형식 오류: %s" % part))
                return None
            if lo > hi:
                lo, hi = hi, lo
            picked |= set(range(lo, hi + 1))
        else:
            try:
                picked.add(int(part))
            except ValueError:
                print(warn("숫자가 아닙니다: %s" % part))
                return None
    bad = [n for n in picked if n < 1 or n > total]
    if bad:
        print(warn("범위를 벗어난 번호: %s (1~%d)"
                   % (", ".join(str(b) for b in sorted(bad)), total)))
        return None
    return picked


def interactive_select(rows, targets):
    """목록에서 삭제할 항목을 번호로 고른다. 취소하면 None."""
    if not sys.stdin.isatty():
        print(warn("비대화형 환경에서는 --select 를 쓸 수 없습니다. "
                   "--pick 1,3,5 형식을 사용하십시오."))
        return None
    default = [n for n, r in enumerate(rows, 1) if r[1] in targets]
    print("\n" + "-" * 62)
    print("  삭제할 항목의 번호를 입력하십시오.")
    print("    예) 1,3,5-8      개별/범위 선택")
    print("        all          전체 선택 (%d건)" % len(rows))
    print("        billable     과금 리소스만 (%d건, 기본값)" % len(default))
    print("        none 또는 q  취소")
    print("-" * 62)
    while True:
        try:
            raw = input("선택> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        low = raw.lower()
        if low in ("q", "quit", "exit"):
            return None
        if low in ("", "billable", "b"):
            if not default:
                print(warn("과금 리소스가 없습니다. 번호를 직접 입력하십시오."))
                continue
            return set(default)
        idx = parse_pick(raw, len(rows))
        if idx is None:
            continue
        if not idx:
            return None
        return idx


def ask_yn(prompt):
    """개별 확인. y 만 삭제, q 는 전체 중단."""
    if not sys.stdin.isatty():
        return True
    while True:
        try:
            a = input(prompt).strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return "quit"
        if a in ("y", "yes"):
            return True
        if a in ("n", "no", ""):
            return False
        if a in ("q", "quit"):
            return "quit"
        print(warn("  y / n / q 중에서 입력하십시오."))


def scan_regions(base_session, regions, owner, account, found, since,
                 profile, tag_key, workers=6):
    """리전별 탐색을 병렬 실행. (notes, elapsed_by_region) 반환."""
    notes, timings = [], {}

    def one(region):
        # botocore 클라이언트는 스레드 간 공유가 안전하지 않으므로
        # 스레드마다 독립 Session 을 만듭니다.
        sess = (boto3.Session(profile_name=profile) if profile
                else boto3.Session())
        t0 = time.time()
        local_notes = []
        note = discover_by_tag(sess, region, owner, account, found, tag_key)
        if note:
            local_notes.append(note)
        seen, note = discover_by_cloudtrail(sess, region, owner, account,
                                            found, since)
        if note:
            local_notes.append(note)
        return region, seen, local_notes, time.time() - t0

    with ThreadPoolExecutor(max_workers=min(workers, len(regions))) as pool:
        futs = {pool.submit(one, r): r for r in regions}
        for fut in as_completed(futs):
            region = futs[fut]
            try:
                region, seen, local_notes, elapsed = fut.result()
            except Exception as e:                           # noqa: BLE001
                notes.append("%s: 탐색 실패(%s)" % (region, clip(e, 50)))
                continue
            timings[region] = elapsed
            print("  %-16s CloudTrail %5d건  (%.1f초)" % (region, seen, elapsed))
            for n in local_notes:
                notes.append("%s: %s" % (region, n))
    return notes, timings


def cache_save(account, owner, regions, since, rows):
    try:
        payload = {
            "version": 2,
            "ts": time.time(),
            "account": account,
            "owner": owner,
            "regions": sorted(regions),
            "since": since.isoformat(),
            "rows": [list(r) for r in rows],
        }
        with open(CACHE_PATH, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        try:
            os.chmod(CACHE_PATH, 0o600)
        except OSError:
            pass
    except Exception:                                        # noqa: BLE001
        pass          # 캐시는 부가 기능이므로 실패해도 무시


def cache_load(account, owner, regions, since):
    """조건이 같고 신선하면 (rows, 경과초) 반환. 아니면 None."""
    try:
        with open(CACHE_PATH, encoding="utf-8") as fh:
            p = json.load(fh)
        if p.get("version") != 2:
            return None
        age = time.time() - float(p.get("ts", 0))
        if age > CACHE_TTL:
            return None
        if (p.get("account") != account or p.get("owner") != owner
                or p.get("regions") != sorted(regions)
                or p.get("since") != since.isoformat()):
            return None
        return [tuple(r) for r in p.get("rows", [])], age
    except Exception:                                        # noqa: BLE001
        return None


def verify_deleted(session, items):
    """삭제 요청한 항목이 실제로 사라졌는지 확인. (사라짐, 남음) 반환."""
    gone, still = [], []
    by_key = defaultdict(list)
    for region, rtype, rid in items:
        by_key[(region, rtype)].append(rid)
    for (region, rtype), ids in by_key.items():
        alive = live_set(session, region, rtype)
        if alive is None:
            still.extend([(region, rtype, i, "확인 불가") for i in ids])
            continue
        alive_norm = {_norm(rtype, a) for a in alive}
        for rid in ids:
            if _norm(rtype, rid) in alive_norm:
                still.append((region, rtype, rid, "아직 존재(삭제 진행 중일 수 있음)"))
            else:
                gone.append((region, rtype, rid))
    return gone, still


def print_option_guide(rows, n_bill, args, regions):
    """scan 결과 아래에 자주 쓰는 옵션을 안내한다."""
    P = "python3 my-cleanup.py"
    print("\n" + "-" * 62)
    print(c("  탐색 범위 조정", "b"))
    print("-" * 62)
    print("  %s scan --days 2" % P)
    print("      최근 2일치. 기본값은 오늘 00:00 UTC(= 09:00 KST) 이후입니다.")
    print("      어제 저녁에 만든 리소스가 안 보이면 이것을 쓰십시오.")
    print("  %s scan --since 2026-08-20" % P)
    print("      특정 날짜(UTC)부터. CloudTrail 보관 한도는 90일입니다.")
    print("  %s scan --regions ap-northeast-2" % P)
    print("      서울 리전만 검색. 리전 수가 줄어 가장 빠릅니다.")
    print("  %s scan --all-regions" % P)
    print("      전 리전 검색. 느리지만 유령 리소스를 놓치지 않습니다.")

    print("\n" + "-" * 62)
    print(c("  표시 옵션", "b"))
    print("-" * 62)
    print("  --include-network   VPC/서브넷/보안그룹 등 무과금 항목까지 표시")
    print("  -v                  '이미 삭제됨'으로 제외된 항목을 상세 표시")
    print("  --cache             직전 스캔 결과 재사용(15분). 기본은 매번 새로 스캔")
    print("  --no-color          색상 끄기 (로그 파일로 저장할 때)")

    print("\n" + "-" * 62)
    print(c("  대상 지정", "b"))
    print("-" * 62)
    print("  --owner stu-01-kevin   다른 사용자가 만든 리소스 조회 (강사용)")
    print("  --tag-key Project      소유자 태그 키를 Owner 대신 다른 값으로")
    print("  --profile seoul        다른 AWS CLI 프로파일 사용")

    print("\n" + "-" * 62)
    print(c("  삭제 방법", "b"))
    print("-" * 62)
    print("  %s delete --apply" % P)
    print("      과금 리소스 전체 삭제 (%d건)" % n_bill)
    print("  %s delete --apply --select" % P)
    print("      목록을 보며 번호로 고르기. 학생 실습에 권장합니다.")
    print("  %s delete --apply --pick 1,3,5-8" % P)
    print("      번호를 직접 지정")
    print("  %s delete --apply --confirm-each" % P)
    print("      리소스마다 y/n 개별 확인")
    print("  %s delete --apply --only s3:bucket" % P)
    print("      특정 타입만 (--only ec2 처럼 서비스 단위도 가능)")
    print("  %s delete --apply --exclude ec2:snapshot" % P)
    print("      특정 타입만 제외")
    print("  옵션 추가:  --verify (삭제 후 자동 확인)   "
          "--include-network (VPC까지)")
    print("\n  전체 옵션:  %s --help" % P)


def confirm(prompt, expect):
    """확인 입력은 항상 영문. 한글 IME 전환 없이 입력할 수 있습니다."""
    if not sys.stdin.isatty():
        print(warn("비대화형 환경입니다. 진행하려면 --yes 를 사용하십시오."))
        return False
    try:
        answer = input(prompt).strip().strip("'\"")
    except (EOFError, KeyboardInterrupt):
        print("\n취소했습니다.")
        return False
    if answer.upper() == expect.upper():
        return True
    print(warn("입력이 '%s' 와 일치하지 않습니다. (입력값: %s)"
               % (expect, answer or "<빈 값>")))
    return False


def main():
    global USE_COLOR
    args = build_parser().parse_args()
    if args.no_color:
        USE_COLOR = False

    signal.signal(signal.SIGINT, STOP.handle)
    try:
        signal.signal(signal.SIGTERM, STOP.handle)
    except (ValueError, AttributeError, OSError):
        pass

    try:
        session = (boto3.Session(profile_name=args.profile) if args.profile
                   else boto3.Session())
    except ProfileNotFound:
        raise SystemExit("프로파일을 찾을 수 없습니다: %s" % args.profile)

    try:
        account, me, kind, _ = whoami(session)
    except NoCredentialsError:
        raise SystemExit("자격 증명이 없습니다. 'aws configure' 를 실행하거나 "
                         "CloudShell 에서 실행하십시오.")
    except ClientError as e:
        raise SystemExit("자격 증명 확인 실패: %s" % err_code(e))
    except EndpointConnectionError:
        raise SystemExit("AWS 에 연결할 수 없습니다. 네트워크를 확인하십시오.")

    owner = args.owner or me
    since = resolve_since(args)

    if args.all_regions:
        try:
            regions = sorted(r["RegionName"] for r in
                             client(session, "ec2", "us-east-1")
                             .describe_regions()["Regions"])
        except Exception:
            print(warn("리전 목록 조회 실패 → 기본 리전 사용"))
            regions = DEFAULT_REGIONS
    elif args.regions:
        regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    else:
        regions = DEFAULT_REGIONS

    line = "=" * 62
    print(line)
    print("  계정      : %s" % account)
    print("  실행 주체 : %s (%s)" % (me, kind))
    print("  소유자    : %s      태그 키: %s" % (owner, args.tag_key))
    print("  기준 시각 : %s UTC  (= %s KST) 이후"
          % (since.strftime("%Y-%m-%d %H:%M"),
             since.astimezone(KST).strftime("%m-%d %H:%M")))
    print("  리전      : %s" % ", ".join(regions))
    print(line)

    if not args.since and not args.days:
        print(warn("  ! 기본 범위는 오늘 00:00 UTC(= 오늘 09:00 KST) 이후입니다."))
        print(warn("    어제 저녁에 만든 리소스까지 찾으려면 --days 2 를 붙이십시오."))

    found = Found()
    notes = []
    t_start = time.time()

    cached = cache_load(account, owner, regions, since) if args.cache else None
    if cached:
        rows_cached, age = cached
        found.load_rows(rows_cached)
        print("\n▶ 최근 스캔 결과 재사용 (%d초 전, %d건). 새로 스캔하려면 --cache 제거"
              % (int(age), len(rows_cached)))
    else:
        if args.cache:
            print("\n▶ 재사용할 최근 스캔 결과가 없습니다. 새로 검색합니다.")
        print("\n▶ 리전 %d곳 병렬 검색 중..." % len(regions))
        notes, _ = scan_regions(session, regions, owner, account, found, since,
                                args.profile, args.tag_key)

    if not STOP.requested:
        print("\n▶ 실제 존재 여부 확인 중...")
        prune_missing(session, found, verbose=True, show_items=args.verbose)

    stats = found.source_stats()
    if stats:
        print("    탐지 경로: %s"
              % ", ".join("%s %d건" % (k, v) for k, v in sorted(stats.items())))
        if not stats.get("tag"):
            print(c("    (태그로 발견된 리소스 0건 — 실습 시 Owner 태그를 붙이면 "
                    "탐지 정확도가 올라갑니다)", "d"))
    print("    소요 시간: %.1f초" % (time.time() - t_start))

    if not cached and not STOP.requested:
        cache_save(account, owner, regions, since, list(found.items()))

    for n in notes:
        print(warn("  ! " + n))
    if STOP.requested:
        print(warn("\n중단되어 결과가 불완전할 수 있습니다."))

    targets = BILLABLE | (NETWORK if args.include_network else set())
    rows = sorted(found.items(), key=lambda x: (x[0], x[1], x[2]))
    n_bill = sum(1 for r in rows if r[1] in BILLABLE)

    print("\n" + line)
    print("  발견된 리소스: 총 %d건 (과금 %d / 무과금·기타 %d)"
          % (len(rows), n_bill, len(rows) - n_bill))
    print(line)

    if not rows:
        print(c("\n  ✅ 정리할 리소스가 없습니다.", "g"))
        if args.command == "scan":
            print("\n  찾는 리소스가 안 보인다면 탐색 범위를 넓혀 보십시오.")
            print("    python3 my-cleanup.py scan --days 2       (어제 것까지)")
            print("    python3 my-cleanup.py scan --all-regions  (전 리전)")
            print("    python3 my-cleanup.py scan --include-network  (VPC 등 포함)")
            print("    python3 my-cleanup.py --help              (전체 옵션)")
        print()
        return 0

    cur = None
    for n, (region, rtype, rid, src) in enumerate(rows, 1):
        if region != cur:
            print("\n[%s]" % region)
            cur = region
        mark = c("$", "r") if rtype in BILLABLE else c("·", "d")
        skip = "" if rtype in targets else c("  (기본 제외)", "d")
        print("  %3d) %s %-34s %-44s %s%s"
              % (n, mark, clip(rtype, 34), clip(rid, 44), c(src, "d"), skip))

    print("\n  %s = 과금 리소스   %s = 무과금(네트워크 등)"
          % (c("$", "r"), c("·", "d")))

    if args.command == "scan":
        print_option_guide(rows, n_bill, args, regions)
        return 0

    # ---------- 삭제 대상 선정 ----------
    if not args.apply:
        print(warn("\n  [DRY-RUN] --apply 가 없어 실제로 삭제하지 않습니다. "
                   "삭제 계획만 확인합니다."))

    # 우선순위: --pick / --select (명시 선택) > --only/--exclude > 기본(과금)
    if args.pick or args.select:
        if args.pick:
            idx = parse_pick(args.pick, len(rows))
        else:
            idx = interactive_select(rows, targets)
        if idx is None:
            print("취소했습니다.")
            return 1
        todo = [(rows[i - 1][0], rows[i - 1][1], rows[i - 1][2]) for i in sorted(idx)]
    else:
        only = split_csv(args.only)
        excl = split_csv(args.exclude)
        todo = []
        for region, rtype, rid, _ in rows:
            if only:
                if not matches_any(rtype, only):
                    continue
            elif rtype not in targets:
                continue
            if excl and matches_any(rtype, excl):
                continue
            todo.append((region, rtype, rid))

    if not todo:
        print(c("\n삭제 대상이 없습니다.", "g"))
        return 0

    print("\n" + line)
    print("  선택된 삭제 대상 %d건" % len(todo))
    for region, rtype, rid in todo:
        print("    - %-16s %-30s %s" % (region, clip(rtype, 30), clip(rid, 44)))
    print(line)

    if not args.apply:
        print(warn("  DRY-RUN 이므로 삭제하지 않았습니다."))
        picked = ",".join(str(i) for i in sorted(
            [n for n, r in enumerate(rows, 1)
             if (r[0], r[1], r[2]) in set(todo)]))
        print("  같은 대상을 실제로 삭제하려면:")
        print("    python3 my-cleanup.py delete --apply --pick %s" % picked)
        print(line)
        return 0

    print(c("  ⚠ 위 %d건을 실제로 삭제합니다. 되돌릴 수 없습니다." % len(todo), "r"))
    print(line)
    if not args.yes and not confirm(
            "\n계속하려면 DELETE 를 입력하십시오 (Type DELETE to continue): ",
            "DELETE"):
        print("취소했습니다.")
        return 1

    order = {t: n for n, t in enumerate(DELETE_ORDER)}
    pending = sorted(todo, key=lambda x: order.get(x[1], 999))
    failures = []
    succeeded = []
    interrupted = False

    for p_no in range(1, max(1, args.passes) + 1):
        if not pending:
            break
        if p_no > 1:
            print("\n▶ 재시도 패스 %d (%d건) — 20초 대기" % (p_no, len(pending)))
            if not STOP.sleep(20):
                interrupted = True
                break
        else:
            print("\n▶ 삭제 패스 %d (%d건)" % (p_no, len(pending)))

        nxt = []
        for idx, (region, rtype, rid) in enumerate(pending):
            if STOP.requested:
                nxt.extend(pending[idx:])
                interrupted = True
                break
            if args.confirm_each and p_no == 1:
                ans = ask_yn("  삭제할까요? %s %s [y/N/q] "
                             % (clip(rtype, 28), clip(rid, 40)))
                if ans == "quit":
                    print(warn("  사용자 요청으로 중단합니다."))
                    interrupted = True
                    break
                if not ans:
                    print("  %s %-30s %-36s %s"
                          % (c("SKIP", "d"), clip(rtype, 30), clip(rid, 36),
                             "건너뜀"))
                    continue
            status, msg = delete_one(session, region, rtype, rid)
            tag = {"ok": c("OK  ", "g"), "retry": c("WAIT", "y"),
                   "fail": c("FAIL", "r")}[status]
            print("  [%s] %-16s %-30s %-36s %s"
                  % (tag, region, clip(rtype, 30), clip(rid, 36), msg))
            if status == "retry":
                nxt.append((region, rtype, rid))
            elif status == "fail":
                failures.append(((region, rtype, rid), msg))
            else:
                succeeded.append((region, rtype, rid))
        pending = nxt
        if interrupted:
            break

    for item in pending:
        failures.append((item, "재시도 소진 - 의존성 미해소"))

    # 삭제했으므로 캐시는 더 이상 유효하지 않음
    try:
        if os.path.exists(CACHE_PATH):
            os.remove(CACHE_PATH)
    except OSError:
        pass

    print("\n" + line)
    if interrupted:
        print(warn("  중단되었습니다. 미처리 %d건이 남아 있습니다." % len(pending)))
    if failures:
        print(warn("  ⚠ %d건 미완료 — 콘솔에서 확인하십시오" % len(failures)))
        for (region, rtype, rid), msg in failures[:40]:
            print("    %s  %s  %s  → %s" % (region, rtype, clip(rid, 40), msg))
        if len(failures) > 40:
            print("    ... 외 %d건" % (len(failures) - 40))
    else:
        print(c("  ✅ 모든 대상 삭제 요청 완료 (%d건)" % len(succeeded), "g"))
    print(line)

    if args.verify and succeeded:
        print("\n▶ 삭제 확인 중 (15초 대기 후 조회)...")
        if STOP.sleep(15):
            gone, still = verify_deleted(session, succeeded)
            print("  사라짐 확인 : %d건" % len(gone))
            if still:
                print(warn("  아직 남음    : %d건" % len(still)))
                for region, rtype, rid, why in still[:20]:
                    print("    %s %s %s → %s"
                          % (region, clip(rtype, 26), clip(rid, 34), why))
                print("  EC2/RDS 등은 종료까지 수 분이 걸립니다. 잠시 후 scan 으로 재확인하십시오.")
            else:
                print(c("  ✅ 선택한 리소스가 모두 제거되었습니다.", "g"))
    else:
        print("\n  삭제는 비동기입니다. 아래로 재확인하십시오.")
        print("    python3 my-cleanup.py scan")
        print("  (삭제 직후 자동 확인하려면 --verify 추가)")
    return 2 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        print("\n중단했습니다.")
        raise SystemExit(130)
    except Exception as exc:                                 # noqa: BLE001
        sys.stderr.write("\n예기치 못한 오류: %s\n" % exc)
        sys.stderr.write("문제가 반복되면 강사에게 위 메시지를 알려주십시오.\n")
        raise SystemExit(1)
