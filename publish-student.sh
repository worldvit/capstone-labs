#!/usr/bin/env bash
# ============================================================
# publish-student.sh — 강사 저장소에서 학생 배포본을 생성한다.
#
#   bash publish-student.sh ../capstone-labs
#
# 강사 저장소가 원본(single source of truth)이다.
# 학생 저장소는 여기서 생성되는 파생물이며 직접 편집하지 않는다.
#
# 학생에게 나가는 것 : 00-common, preflight.sh, verify.sh, teardown.sh,
#                      setup-*.sh(플레이스홀더 상태), 문서
# 학생에게 안 나가는 것: build.sh, repair.sh, build-all.sh, mock-aws, test-common.sh
#
# setup-*.sh 를 내보내는 이유:
#   따라하기형 실습 문서가 이 스크립트를 sed 로 치환해 쓰도록 설계되어 있다.
#   JSP·nginx.conf·CloudWatch Agent JSON 은 따옴표와 중괄호가 많아
#   문서에 전문을 싣고 학생이 복사하면 반드시 어긋난다.
#   대신 값이 박히지 않았는지(플레이스홀더 유지) 5단계에서 검사한다.
# ============================================================
set -euo pipefail

DEST="${1:-}"
[ -n "$DEST" ] || { echo "사용법: bash publish-student.sh <학생저장소경로>"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
ok(){ printf '%s[✔]%s %s\n' "$C_G" "$C_0" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die(){ printf '%s[✘]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

[ -d "$DEST/.git" ] || die "$DEST 는 git 저장소가 아닙니다. 먼저 clone 하십시오."
[ -d "$SRC/00-common" ] || die "$SRC 가 강사 저장소가 아닌 것 같습니다."

printf '\n원본: %s\n대상: %s\n\n' "$SRC" "$DEST"

# ---------- 1. 기존 배포본 비우기 (.git 은 보존) ----------
find "$DEST" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
ok "대상 저장소 초기화 (.git 보존)"

# ---------- 2. 공통 계층 — 전량 복사 ----------
mkdir -p "$DEST/00-common"
cp "$SRC/00-common/"*.sh "$DEST/00-common/"
ok "00-common 5개 파일 복사"

# ---------- 3. 학생이 실행할 스크립트만 ----------
for f in preflight.sh verify-all.sh; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
done
ok "preflight.sh, verify-all.sh 복사"

# ---------- 4. 랩별 — verify / teardown 만 ----------
n=0
for d in "$SRC"/lab*/; do
  [ -d "$d" ] || continue
  lab="$(basename "$d")"
  mkdir -p "$DEST/$lab"
  # verify.sh  : 자기 채점
  # teardown.sh : 정리(비용 관리)
  # analyze.sh  : 로그 분석 — 읽기 전용이라 학생에게 주어도 안전하다
  for f in verify.sh teardown.sh analyze.sh loadtest.sh; do
    [ -f "$d/$f" ] && cp "$d/$f" "$DEST/$lab/"
  done
  # setup-*.sh : 따라하기형 문서가 sed 로 치환해 쓰는 구성 스크립트
  #              플레이스홀더 상태 그대로 내보낸다(값은 학생이 채운다)
  for f in "$d"setup-*.sh; do
    [ -f "$f" ] && cp "$f" "$DEST/$lab/"
  done
  n=$((n+1))
done
ok "랩 ${n}개의 verify / teardown / analyze / loadtest / setup 복사"

# ---------- 5. 유출 검사 ----------
leak=0
while IFS= read -r f; do
  warn "유출 의심 파일: ${f#$DEST/}"; leak=$((leak+1))
done < <(find "$DEST" \( -name 'build*.sh' -o -name 'repair.sh' -o -name 'mock-aws' \
           -o -name 'test-common.sh' -o -name 'publish-student.sh' \
           -o -name 'gen-diagram.py' -o -path '*/tools/*' \) 2>/dev/null)
[ "$leak" -eq 0 ] && ok "유출 검사 통과 — build/repair 계열 없음" \
                  || die "유출 파일 ${leak}건 — 스크립트를 점검하십시오"

# ---------- 5-2. setup-*.sh 값 박힘 검사 ----------
# setup 스크립트는 내보내되, 실제 계정번호·엔드포인트·시크릿이
# 치환된 채로 나가면 안 된다. 플레이스홀더가 살아 있는지 확인한다.
baked=0
while IFS= read -r f; do
  rel="${f#$DEST/}"
  # 플레이스홀더가 하나도 없으면 이미 치환된 파일이다
  if ! grep -qE '__[A-Z_]+__' "$f"; then
    warn "플레이스홀더 없음(치환된 파일 의심): $rel"; baked=$((baked+1))
  fi
  # 실제 값이 박혀 있으면 즉시 중단
  if grep -qE '[0-9]{12}|\.rds\.amazonaws\.com|fs-[0-9a-f]{8,}|vpce-[0-9a-f]{8,}' "$f"; then
    warn "실제 값 박힘: $rel"; baked=$((baked+1))
  fi
done < <(find "$DEST" -name 'setup-*.sh' 2>/dev/null)
[ "$baked" -eq 0 ] && ok "setup 스크립트 검사 통과 — 플레이스홀더 유지" \
                   || die "setup 스크립트 ${baked}건 이상 — 값이 박힌 채 나갑니다"

# ---------- 6. 학생용 부속 파일 ----------
cat > "$DEST/.gitattributes" << 'EOF'
* text=auto eol=lf
*.sh text eol=lf
EOF

cat > "$DEST/.gitignore" << 'EOF'
# 실행 중 생성되는 것 — 커밋하지 않는다
state/
*.bak
student.env
EOF

cat > "$DEST/student.env.example" << 'EOF'
# ============================================================
# 개인 계정으로 실습한다면 이 파일은 필요 없습니다.
# 아무것도 하지 않아도 아래 기본값이 그대로 적용됩니다.
#
#   PREFIX=cap          리소스 이름 접두사  (cap-vpc-svc, cap-rds ...)
#   STUDENT_BASE=1      VPC 대역           (svc 10.1.0.0/16, mgmt 10.2.0.0/16)
#   REGION=ap-northeast-2
#
# 값을 바꾸면 실습 문서에 적힌 이름·대역과 달라져
# 문서를 그대로 따라갈 수 없게 됩니다. 권장하지 않습니다.
# ============================================================
#
# 그래도 바꿔야 한다면(예: 한 계정에 두 벌을 만들어 비교):
#   cp student.env.example student.env
#   vi student.env                # 주석을 풀고 값 수정
#   source student.env
#
# export PREFIX=cap2
# export STUDENT_BASE=21          # svc 10.21, mgmt 10.22
# export REGION=ap-northeast-2

# 상태 파일 S3 백업을 끄려면 0 으로 바꾸십시오.
# 버킷 이름은 지정하지 않으면 cap-state-<계정번호> 로 자동 생성됩니다.
# export STATE_SYNC=1
# export STATE_BUCKET=
EOF

cat > "$DEST/README.md" << 'READMEEOF'
# 캡스톤 실습 — 학생용

AWS 콘솔과 CLI로 3계층 아키텍처를 **14개 랩에 걸쳐 누적 구축**합니다.
Lab 1에서 만든 것 위에 Lab 2를 얹고, 그 위에 Lab 3을 얹는 방식입니다.

각 랩은 **60~80분**을 기준으로 설계되어 있습니다.

---

## 목차

1. [시작하기 전에](#1-시작하기-전에)
2. [최초 1회 준비](#2-최초-1회-준비)
3. [매 실습 시작 절차](#3-매-실습-시작-절차)
4. [실습 진행 방법](#4-실습-진행-방법)
5. [랩 목록과 순서](#5-랩-목록과-순서)
6. [스스로 채점하기](#6-스스로-채점하기)
7. [막혔을 때](#7-막혔을-때)
8. [로그 분석 (Lab 9 이후)](#8-로그-분석-lab-9-이후)
9. [비용 관리와 정리](#9-비용-관리와-정리)
10. [환경이 초기화됐을 때](#10-환경이-초기화됐을-때)
11. [자주 묻는 질문](#11-자주-묻는-질문)

---

## 1. 시작하기 전에

### 필요한 것

| 항목 | 내용 |
|---|---|
| AWS 계정 | 본인에게 배정된 **개인 계정** |
| 리전 | `ap-northeast-2` (서울) |
| 작업 환경 | AWS 콘솔 + CloudShell (설치할 것 없음) |
| 실습 문서 | 노션 각 랩 페이지 |

**본인 계정을 혼자 씁니다.** 다른 학생과 리소스가 겹치지 않으므로
접두사(`cap`)와 VPC 대역(`10.1`, `10.2`)을 그대로 쓰면 됩니다.

### 실습에 쓰는 이름 규칙

모든 리소스 이름은 `cap-` 으로 시작합니다.

```
cap-vpc-svc      서비스 VPC (10.1.0.0/16)
cap-vpc-mgmt     관리 VPC   (10.2.0.0/16)
cap-app-a        App 서버 (가용영역 a)
cap-rds          데이터베이스
cap-alb          로드 밸런서
```

콘솔에서 `cap` 으로 검색하면 본인이 만든 것만 보입니다.

---

## 2. 최초 1회 준비

**과정 시작 첫날 한 번만** 하면 됩니다.

### 2.1 콘솔 로그인과 리전 확인

배정받은 계정으로 로그인한 뒤, **우측 상단 리전을
`아시아 태평양(서울) ap-northeast-2` 로 바꿉니다.**

> 리전이 다르면 이후 모든 실습이 어긋납니다.
> 만든 리소스가 "안 보인다"면 십중팔구 리전 문제입니다.

### 2.2 CloudShell 열기

콘솔 우측 상단의 터미널 아이콘(`>_`)을 클릭합니다.

```bash
aws sts get-caller-identity --region ap-northeast-2
```

계정 번호가 나오면 정상입니다. **자격 증명을 따로 설정할 필요가 없습니다.**

### 2.3 저장소 내려받기

```bash
cd ~
git clone https://github.com/worldvit/capstone-labs.git
cd capstone-labs
chmod +x 00-common/*.sh *.sh lab*/*.sh
ls
```

**예상 출력**

```
00-common  lab01-iam  lab02-vpc  lab03-network  ...  preflight.sh  verify-all.sh
```

### 2.4 사전 점검

```bash
cd ~/capstone-labs
bash preflight.sh
```

AWS CLI 버전, 자격 증명, 가용 영역, 기존 리소스 유무를 확인합니다.
마지막에 `사전 점검 통과` 가 나오면 준비 완료입니다.

> **`source preflight.sh` 로 실행하지 마십시오.**
> 반드시 `bash preflight.sh` 입니다. `source` 로 하면 셸이 종료될 수 있습니다.

### 2.5 키 페어 만들기

Lab 4에서 EC2에 접속할 때 씁니다. **지금 미리 만들어 두십시오.**

```bash
aws ec2 create-key-pair --key-name cap-key \
  --query 'KeyMaterial' --output text \
  --region ap-northeast-2 > ~/cap-key.pem
chmod 400 ~/cap-key.pem
echo "생성 완료 — 본인 PC로도 내려받으십시오"
```

> **이 파일은 한 번만 받을 수 있습니다.**
> CloudShell 우측 상단 **작업 → 파일 다운로드** 로 `~/cap-key.pem` 을
> 본인 PC에도 저장하십시오.
> 잃어버리면 키 페어를 지우고 다시 만들어야 하며,
> 그 키로 만든 서버에는 다시 접속할 수 없습니다.

### 2.6 준비 완료 확인

```bash
cd ~/capstone-labs
printf '계정   : '; aws sts get-caller-identity --query Account --output text --region ap-northeast-2
printf '키페어 : '; aws ec2 describe-key-pairs --key-names cap-key \
  --query 'KeyPairs[0].KeyName' --output text --region ap-northeast-2
printf '저장소 : '; ls preflight.sh >/dev/null 2>&1 && echo OK || echo 없음
```

**예상 출력**

```
계정   : 123456789012
키페어 : cap-key
저장소 : OK
```

세 줄이 모두 나오면 Lab 1을 시작할 수 있습니다.

---

## 3. 매 실습 시작 절차

**매번 실습을 시작할 때** 아래 세 가지를 확인합니다. 30초면 됩니다.

```bash
# 1) 리전 확인 — 콘솔 우측 상단이 '서울' 인가
# 2) CloudShell 열기
# 3) 저장소 최신화
cd ~/capstone-labs && git pull
```

> CloudShell은 오래 안 쓰면 세션이 끊깁니다.
> `~` 디렉터리(1GB)는 보존되므로 저장소는 그대로 있습니다.
> 끊겼으면 다시 열고 `cd ~/capstone-labs` 만 하면 됩니다.

---

## 4. 실습 진행 방법

각 랩마다 노션 문서가 **두 개**입니다.

| 문서 | 성격 | 언제 씁니까 |
|---|---|---|
| **지시형** | 과제형. 무엇을 만들지만 알려줍니다 | **먼저 이것으로 스스로** 해봅니다 |
| **따라하기형** | 정답형. 클릭 경로와 명령을 하나씩 안내합니다 | **막혔을 때** 같은 번호를 펼칩니다 |

### 권장 진행 순서

```
1. 지시형 문서의 "시나리오" 를 읽습니다 — 왜 이걸 만드는가
2. "요구사항" 만 보고 콘솔에서 직접 만들어 봅니다
3. 각 태스크의 "자가 확인" 명령으로 스스로 점검합니다
4. 막히면 → 따라하기형 문서의 같은 태스크 번호를 펼칩니다
5. 랩이 끝나면 verify.sh 로 채점합니다
```

**바로 따라하기형을 펴지 마십시오.** 손은 움직이지만 남는 것이 없습니다.
15분 고민해도 안 풀리면 그때 펴는 것이 가장 좋습니다.

---

## 5. 랩 목록과 순서

**순서대로 진행해야 합니다.** 뒤 랩은 앞 랩의 산출물 위에 쌓입니다.

| 랩 | 폴더 | 주제 | 앞 랩 의존 |
|---|---|---|---|
| 1 | `lab01-iam` | IAM 권한 체계 | — |
| 2 | `lab02-vpc` | VPC와 서브넷 12개 | — |
| 3 | `lab03-network` | NAT · 라우팅 · 보안 그룹 | 2 |
| 4 | `lab04-ec2` | EC2와 Session Manager | 1, 3 |
| 5 | `lab05-endpoint-tgw` | VPC 엔드포인트 · Transit Gateway | 3, 4 |
| 6 | `lab06-s3` | S3 정적 콘텐츠 · 접근 경로 제한 | 5 |
| 7 | `lab07-efs` | EFS 공유 스토리지 | 4 |
| 8 | `lab08-aurora` | RDS PostgreSQL 다중 AZ | 3 |
| 8.5 | `lab08b-3tier` | 3계층 연결 (nginx → Tomcat → DB) | 4, 8 |
| 9 | `lab09-observability` | 지표 · 로그 · 감사 | 8.5 |
| 10 | `lab10-alb-asg` | ALB와 Auto Scaling | 7, 8, 8.5 |
| 11 | `lab11-cloudfront-waf` | CloudFront와 WAF | 6, 10 |
| 12 | `lab12-serverless` | SNS · SQS · Lambda · API Gateway | 6, 11 |
| 13 | `lab13-backup` | 백업 전략과 종단 검증 | 전부 |

> **Lab 8.5는 8과 9 사이입니다.** 폴더 이름이 `lab08b-3tier` 인 이유입니다.

---

## 6. 스스로 채점하기

랩을 마쳤다고 생각하면 채점 스크립트를 돌립니다.

```bash
cd ~/capstone-labs
bash lab01-iam/verify.sh
```

**예상 출력**

```
[Lab 1  IAM 권한 체계]
  PASS  IAM 역할 cap-ec2-role 존재
  PASS  역할에 SSM 정책 연결
  FAIL  MFA 강제 정책 존재
  ---
  결과: 13/14  실패 1
```

`FAIL` 이 뜬 항목만 다시 구성하면 됩니다.
실습 문서 끝의 **"채점"** 절에 어느 태스크로 돌아가야 하는지 표가 있습니다.

### 여러 랩을 한번에

```bash
bash verify-all.sh        # 전체 랩 진단
bash verify-all.sh 5      # Lab 1~5 까지만
```

앞 랩이 깨졌는데 모르고 다음으로 넘어가는 것을 막아줍니다.
**새 랩을 시작하기 전에 한 번 돌려보는 것을 권합니다.**

---

## 7. 막혔을 때

아래 순서로 확인하십시오. 대부분 여기서 풀립니다.

### 7.1 리전이 서울인가

콘솔 우측 상단과 CLI 명령의 `--region ap-northeast-2` 를 확인합니다.
**가장 흔한 원인입니다.**

### 7.2 앞 랩이 살아 있는가

```bash
bash verify-all.sh
```

Lab 5가 안 되는 이유가 Lab 3의 라우팅 때문인 경우가 많습니다.

### 7.3 실습 문서의 "문제 해결" 표를 봅니다

각 문서 끝에 **증상 → 원인 → 어느 단계로 돌아갈지** 표가 있습니다.
화면에 뜬 오류 메시지를 그대로 찾아보십시오.

### 7.4 리소스가 실제로 있는지 직접 확인합니다

```bash
# 이 계정의 캡스톤 리소스 한눈에 보기
printf 'VPC       : '; aws ec2 describe-vpcs --region ap-northeast-2 \
  --filters "Name=tag:Owner,Values=cap" --query 'length(Vpcs)' --output text
printf 'EC2(실행) : '; aws ec2 describe-instances --region ap-northeast-2 \
  --filters "Name=tag:Owner,Values=cap" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[])' --output text
printf 'RDS       : '; aws rds describe-db-instances --region ap-northeast-2 \
  --query 'length(DBInstances)' --output text
printf 'ALB       : '; aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query 'length(LoadBalancers)' --output text
```

### 7.5 서버 구성 스크립트 (`setup-*.sh`)

일부 랩에는 `setup-` 으로 시작하는 스크립트가 들어 있습니다.
Tomcat · nginx · CloudWatch Agent 설정처럼 **따옴표와 중괄호가 많아
문서에 옮겨 적으면 반드시 어긋나는** 것들입니다.

| 랩 | 스크립트 | 채워야 할 빈칸 |
|---|---|---|
| `lab08b-3tier` | `setup-tomcat.sh` | 리전, DB 엔드포인트 · 포트 · 이름, 시크릿 ARN |
| `lab08b-3tier` | `setup-nginx.sh` | App 서버 업스트림 목록 |
| `lab09-observability` | `setup-cwagent.sh` | 로그 그룹 이름, 역할 |
| `lab10-alb-asg` | `setup-app-node.sh` | 위 항목 + EFS ID |

이 파일들은 `__DB_ENDPOINT__` 같은 **빈칸 상태로 배포**됩니다.

```bash
# 어떤 빈칸이 있는지 먼저 봅니다
grep -oE '__[A-Z_]+__' lab08b-3tier/setup-tomcat.sh | sort -u

# 무엇을 하는 스크립트인지 읽어 봅니다 — 그대로 실행하지 마십시오
less lab08b-3tier/setup-tomcat.sh
```

**빈칸을 채우지 않고 실행하면 서버가 뜨지 않습니다. 그것이 정상입니다.**
실습 문서가 안내하는 `sed` 명령으로 본인 계정의 값을 채워 쓰십시오.
어떤 값이 어디에 쓰이는지 이해하는 것이 이 랩의 목적입니다.

> DB 비밀번호는 스크립트에 넣지 않습니다.
> **시크릿 ARN만** 넣고, 애플리케이션이 실행 시점에
> Secrets Manager에서 직접 읽어옵니다.

---

## 8. 로그 분석 (Lab 9 이후)

Lab 9부터는 수집된 로그를 직접 읽어 봅니다.
**구축이 끝이 아니라 해석이 시작입니다.**

```bash
bash lab09-observability/analyze.sh --list    # 분석 항목 보기
bash lab09-observability/analyze.sh           # 전체 실행
bash lab09-observability/analyze.sh 5         # 5번 항목만
MINUTES=360 bash lab09-observability/analyze.sh   # 기간 넓히기 (기본 60분)
```

8가지 질문에 답합니다.

```
1. nginx 상태 코드 분포 — 서비스가 건강한가
2. 응답 시간 상위       — 어느 요청이 느린가
3. 요청이 두 App 서버에 고르게 분산되는가
4. Tomcat 오류 로그     — 예외가 나는가
5. Flow Logs 거부 트래픽 — 누가 무엇을 두드리는가
6. 3계층 통신 경로      — 설계대로 흐르는가
7. CloudTrail          — 누가 무엇을 바꿨는가
8. 지표 요약           — CPU · 메모리 · DB 연결
```

각 항목은 **"무엇을 묻는가 → 어떻게 묻는가 → 무엇을 읽어내는가"** 순으로 나옵니다.

> 결과가 비어 있으면 트래픽이 없는 것입니다.
> 브라우저로 몇 번 접속한 뒤 **3~5분 기다렸다가** 다시 실행하십시오.

---

## 9. 비용 관리와 정리

### 무엇이 비싼가

| 리소스 | 대략 하루 비용 | 언제 만듭니까 |
|---|---|---|
| NAT 게이트웨이 | 약 $2.9 | Lab 3 |
| RDS 다중 AZ | 약 $1.4 | Lab 8 |
| Transit Gateway | 약 $2.4 | Lab 5 |
| ALB | 약 $0.7 | Lab 10 |
| WAF | **월 $8 (일할 안 됨)** | Lab 11 |
| EC2 (t3.micro) | 약 $0.3/대 | Lab 4, 8.5 |

**켜두면 계속 나갑니다.** 수업이 끝나면 정리하십시오.

### 랩별 정리

```bash
bash lab11-cloudfront-waf/teardown.sh
```

확인 프롬프트에 `delete` 를 입력합니다.

> **확인 프롬프트가 뜨면 여러 명령을 한꺼번에 붙여넣지 마십시오.**
> 뒤의 명령이 프롬프트 입력으로 빨려 들어가 취소됩니다. 한 줄씩 실행하십시오.

### 전체 정리 순서

전체를 정리할 때는 **만든 순서의 역순**으로 지웁니다.
앞 랩 리소스를 먼저 지우면 뒤 랩 정리가 실패합니다.

```bash
cd ~/capstone-labs
for L in lab13-backup lab12-serverless lab11-cloudfront-waf lab10-alb-asg \
         lab09-observability lab08b-3tier lab08-aurora lab07-efs \
         lab06-s3 lab05-endpoint-tgw lab04-ec2 lab03-network \
         lab02-vpc lab01-iam; do
  echo "=== $L ==="
  bash $L/teardown.sh
done
```

**전체 정리에 30~40분 걸립니다.** CloudFront 배포 삭제만 15~20분입니다.

### 정리 후 확인

```bash
printf 'EIP : '; aws ec2 describe-addresses --region ap-northeast-2 \
  --query 'length(Addresses)' --output text
printf 'NAT : '; aws ec2 describe-nat-gateways --region ap-northeast-2 \
  --query 'length(NatGateways[?State==`available`])' --output text
printf 'RDS : '; aws rds describe-db-instances --region ap-northeast-2 \
  --query 'length(DBInstances)' --output text
printf 'ALB : '; aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query 'length(LoadBalancers)' --output text
printf 'WAF : '; aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query 'length(WebACLs)' --output text
```

모두 `0` 이어야 합니다.

> **탄력적 IP(EIP)를 특히 확인하십시오.**
> 어디에도 연결되지 않은 채 남아 있으면 **오히려 과금**됩니다.

---

## 10. 환경이 초기화됐을 때

CloudShell은 오래 안 쓰면 `~` 를 제외한 나머지가 초기화됩니다.
AWS에 만든 리소스는 그대로 있으므로 **저장소만 되살리면** 됩니다.

```bash
cd ~
[ -d capstone-labs ] || git clone https://github.com/worldvit/capstone-labs.git
cd capstone-labs
git pull
chmod +x 00-common/*.sh *.sh lab*/*.sh
bash verify-all.sh          # 어디까지 살아 있는지 확인
```

### 랩 간 인계 정보 (`state/`)

랩에서 만든 리소스 ID는 `state/cap.env` 에 기록되어 다음 랩이 씁니다.
이 파일이 없으면 뒤 랩의 스크립트가 앞 랩 리소스를 못 찾습니다.

```bash
bash 00-common/state-sync.sh pull     # S3 백업에서 복원
bash 00-common/state-sync.sh push     # S3로 백업
```

> `state/` 디렉터리를 **직접 수정하지 마십시오.**
> 값이 어긋나면 이후 랩이 엉뚱한 리소스를 가리킵니다.

---

## 11. 자주 묻는 질문

**Q. `student.env` 를 만들라는 안내를 봤습니다.**

개인 계정으로 실습하므로 **만들지 않아도 됩니다.**
기본값(`PREFIX=cap`, `STUDENT_BASE=1`, 리전 서울)이 그대로 적용됩니다.

---

**Q. 만든 리소스가 콘솔에 안 보입니다.**

리전을 확인하십시오. 우측 상단이 **서울(ap-northeast-2)** 이어야 합니다.
Lab 11의 WAF만 예외로 **버지니아 북부(us-east-1)** 에 있습니다.

---

**Q. `verify.sh` 가 `FAIL` 인데 콘솔에는 리소스가 보입니다.**

이름이나 태그가 다를 가능성이 큽니다.
`cap-` 접두사와 `Project=capstone`, `Owner=cap` 태그를 확인하십시오.
채점 스크립트는 **태그로 리소스를 찾습니다.**

---

**Q. 실습 중간에 시간이 다 됐습니다. 내일 이어서 해도 됩니까?**

됩니다. 리소스는 그대로 있습니다.
다만 **NAT · RDS · ALB는 밤새 과금**되므로,
며칠 뒤에 이어할 예정이면 해당 랩만 정리하고 다시 만드는 편이 쌉니다.

---

**Q. `teardown.sh` 를 돌렸는데 일부가 안 지워집니다.**

의존 관계 때문입니다. **역순으로** 지우십시오(9절 참고).
그래도 남으면 콘솔에서 직접 삭제하고 `verify.sh` 로 확인하십시오.

---

**Q. 키 페어(`cap-key.pem`)를 잃어버렸습니다.**

기존 키 페어를 지우고 다시 만들어야 합니다.
그 키로 만든 EC2에는 SSH로 접속할 수 없지만,
**Session Manager로는 접속할 수 있습니다.**

```bash
aws ssm start-session --target <인스턴스ID> --region ap-northeast-2
```

Lab 1에서 만든 IAM 역할 덕분입니다. SSH 키 없이 서버에 들어가는 것이
Session Manager의 요점입니다.

---

**Q. 비용이 얼마나 나왔는지 보고 싶습니다.**

콘솔에서 **Billing and Cost Management → 비용 탐색기** 를 엽니다.
태그별로 묶어 보면 `Project=capstone` 이 얼마인지 알 수 있습니다.

---

## 도움을 요청하기 전에

강사에게 질문하기 전에 아래를 준비하면 훨씬 빨리 해결됩니다.

```
1. 어느 랩, 어느 태스크 번호에서 막혔는가
2. 화면에 뜬 오류 메시지 원문 (스크린샷보다 텍스트가 낫습니다)
3. bash verify-all.sh 결과
4. 실습 문서의 "문제 해결" 표를 확인했는가
```
READMEEOF
ok "README.md, .gitignore, .gitattributes, student.env.example 생성"

# ---------- 7. 결과 ----------
printf '\n%s생성된 파일%s\n' "$C_Y" "$C_0"
(cd "$DEST" && find . -path ./.git -prune -o -type f -print | sort | sed 's|^\./|  |')

printf '\n%s다음 단계%s\n' "$C_Y" "$C_0"
cat << NEXT
  cd $DEST
  git add -A
  git commit -m "Publish student distribution"
  git push
NEXT
