# 캡스톤 실습 — 학생용

AWS 콘솔과 CLI로 3계층 아키텍처를 13개 랩에 걸쳐 누적 구축합니다.
Lab 1에서 만든 것 위에 Lab 2를 얹고, 그 위에 Lab 3을 얹는 방식입니다.

## 시작하기

AWS 콘솔에 로그인한 뒤 리전이 **서울(ap-northeast-2)** 인지 확인하고 CloudShell을 엽니다.

```bash
git clone https://github.com/worldvit/capstone-labs.git
cd capstone-labs
chmod +x 00-common/*.sh *.sh lab*/*.sh
mkdir -p state

cp student.env.example student.env
vi student.env                    # 강사가 배정한 값 입력
echo '[ -f ~/capstone-labs/student.env ] && . ~/capstone-labs/student.env' >> ~/.bashrc
source student.env

bash preflight.sh
```

**명명 미리보기**의 접두사와 VPC 대역이 배정받은 값과 같은지 반드시 확인하십시오.

## 실습 진행

각 랩의 과제는 실습 문서를 따릅니다. 구축을 마치면 스스로 채점하십시오.

```bash
bash lab01-iam/verify.sh          # 해당 랩만 채점
bash verify-all.sh 5              # Lab 1~5 전체 진단
```

`PASS` / `FAIL`이 항목별로 나옵니다. `FAIL`이 뜨면 그 항목만 다시 구성하면 됩니다.

## 로그 분석

Lab 9 이후에는 수집된 로그를 직접 읽어 봅니다. 구축이 끝이 아니라 해석이 시작입니다.

```bash
bash lab09-observability/analyze.sh --list    # 분석 항목 보기
bash lab09-observability/analyze.sh           # 전체 실행
bash lab09-observability/analyze.sh 5         # 5번 항목만
MINUTES=360 bash lab09-observability/analyze.sh   # 기간 넓히기
```

각 항목은 "무엇을 묻는가 → 어떻게 묻는가 → 무엇을 읽어내는가" 순으로 나옵니다.
데이터가 비어 있으면 트래픽을 만든 뒤 3~5분 기다리십시오.

## 다른 PC에서 이어하기

랩에서 만든 리소스 ID는 S3에 자동 백업됩니다.

```bash
bash 00-common/state-sync.sh pull
bash verify-all.sh
```

## 정리

과제 제출과 채점이 끝난 랩은 정리해 비용을 줄이십시오.

```bash
bash lab03-network/teardown.sh    # 특정 랩만
```

NAT 게이트웨이, Aurora, ALB는 켜두면 계속 과금됩니다.

## 주의

- `state/` 디렉터리는 직접 수정하지 마십시오. 랩 간 인계 정보가 들어 있습니다.
- 배정받은 `PREFIX`와 `STUDENT_BASE`를 임의로 바꾸면 다른 학생 리소스와 충돌합니다.
