# 서울·부산 주요 아파트 실거래가

서울·부산 주요 아파트의 실거래 데이터를 실제 공급면적 평형 기준으로 보여주는 정적 웹사이트입니다. 국토교통부 원본 전용면적㎡는 그대로 보존하고, 단지별 실제 면적 타입과 일치시킨 공급면적 평형을 화면·필터·그래프에 사용합니다. GitHub Pages는 저장소의 `public/` 폴더만 배포합니다.

홈페이지: https://jaehun242.github.io/Apart-price/

현재 카탈로그는 261개 단지입니다. 직전 수집 기준 236개가 식별됐고, 기존 거래가 없는 추가 후보 25개는 임의로 매칭하지 않고 보류 중입니다. 단지 수와 매칭 상태는 실행 진단 자료에서 확인합니다.

## 자동갱신

GitHub Actions의 `Daily apartment transaction update` workflow 하나가 수집부터 Pages 배포까지 처리합니다. 예약은 **한국시간 매일 오전 7시**이며, YAML의 `0 22 * * *`는 전날 22:00 UTC = 다음 날 07:00 Asia/Seoul입니다. GitHub 사정에 따라 실제 시작은 지연될 수 있습니다.

- 예약 실행: 새로 수집 → 검증 → 변경 시에만 commit/push → 같은 실행에서 Pages 배포
- 사람이 `main`에 push: 현재 main을 검증해 Pages 배포만 수행. 단, 단지 카탈로그 설정 변경은 기존처럼 수집부터 수행
- 수동 `refresh` (기본값): 새 수집과 배포
- 수동 `auto`: 당일 검증된 수집 결과와 코드·데이터가 동일하면 재사용하고, 아니면 새로 수집
- 수동 `deploy-only`: API 호출·데이터 변경·커밋 없이 저장된 main만 재배포

모든 실행은 같은 concurrency 그룹을 사용하고 진행 중 실행을 취소하지 않습니다. 별도 push 배포 workflow는 제거했습니다. `GITHUB_TOKEN`이 만든 push가 다른 workflow를 시작할 것이라고 가정하지 않습니다.

갱신 순서:

1. GitHub Repository Secret `MOLIT_API_KEY`로 국토교통부 공식 실거래가 OpenAPI 호출
2. 41개 법정동 지역코드의 최근 6개월을 월별로 재조회
3. 단지명·법정동·지번·전용면적·기존 거래를 대조해 기존 단지를 매칭하고 식별 불가능한 추가 후보는 명시적으로 보류
4. 기존 `transactionId`와 안정적인 거래 추적키를 함께 비교해 신규·취소·정정·늦은 신고 반영 및 중복 제거
5. 처음 발견한 신규 거래에만 한국 날짜 `first_seen_at`을 기록하고, 정정·재수집 거래는 기존 최초수집일 유지
6. 날짜·필수값·단지 수·거래 수 급감 여부 검증
7. 모든 API 호출과 검증이 성공한 경우에만 `public/data/transactions.js`를 원자적으로 교체
8. 거래가 바뀌면 저장된 실제 단지 타입 자료로 공급면적 매핑과 확인 필요 보고서를 다시 생성·검증
9. 실제 데이터가 바뀐 경우에만 거래 원본·공급면적 매핑·보고서를 `main`에 commit/push
10. 게시할 파일이 검증된 최신 `origin/main`과 같은지 확인하고 `public/data/build-meta.json` 생성
11. 같은 workflow에서 `actions/configure-pages@v5` → `actions/upload-pages-artifact@v4` → `actions/deploy-pages@v4` 실행
12. 공식 Pages 배포 Action이 성공해야 최종 성공 처리. 데이터 변경이 없는 날도 배포 단계는 수행

조회 또는 검증에 실패하면 기존 데이터 파일은 변경하지 않으며 commit/push도 실행되지 않습니다.

API timeout/connection reset/429/5xx는 연결 25초·읽기 60초 제한과 5/15/30/60/120초 대기로 최대 6회 시도합니다. 인증 오류는 즉시 중단합니다. 일부 조회만 성공한 자료는 게시하지 않습니다. 수집·중복 검사·취소 제거·기존 최초수집일 유지 로직은 이전 과정에서 변경하지 않았습니다.

배포 결과는 Pages Action으로 판단합니다. 예전 호스팅 URL 조회나 외부 호스팅 키는 더 이상 사용하지 않습니다. 생성 메타데이터의 `commit_sha`는 실제 게시한 HEAD이며, workflow를 시작한 커밋은 `workflow_commit_sha`로 별도 기록합니다. 자동수집이 만든 데이터 커밋과 시작 커밋은 서로 다를 수 있습니다.

메인페이지의 **이번 주 신규 실거래**는 실제 계약일이 아니라 `first_seen_at`(우리 시스템의 최초 수집일)로 집계합니다. 가격 그래프·시세 계산·기간별 통계와 거래 카드에 표시하는 계약일은 계속 실제 계약일 기준입니다. 추적 도입 전 기존 거래는 `first_seen_at: null`로 초기화해 도입 주에 신규 거래로 잘못 집계되지 않도록 했습니다.

최초 추적 도입 주(2026-08-24 시작)는 Git의 월요일 직전 데이터와 8월 26·27일 자동수집 스냅샷을 거래 추적키로 비교해 복원했습니다. 수집기 전환으로 바뀐 거래 ID는 기존 거래로 연결하고, 당시 처음 등장했으며 현재도 유효한 105건만 실제 최초 등장일을 기록했습니다. 거래별 근거는 `reports/weekly-first-seen-backfill-2026-08-24.md`에 보존합니다.

## 데이터 소스

- 국토교통부 아파트 매매 실거래가 상세자료 공식 OpenAPI: `https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev`
- 실제 단지 공급/전용 면적 타입: 아실 단지정보 `https://asil.kr/app/apt_info.jsp`

OpenAPI 키는 코드나 로그에 저장하지 않고 GitHub Actions의 `secrets.MOLIT_API_KEY`로만 전달합니다. API 접근이 차단되거나 응답·단지 매칭·검증에 실패하면 workflow는 실패로 종료하며 기존 데이터는 유지하고 임의 데이터나 샘플 데이터로 대체하지 않습니다.

## 저장소 구조

- `public/`: GitHub Pages가 배포하는 홈페이지 파일
- `public/data/transactions.js`: 검증된 공개 실거래 데이터
- `public/data/supply-areas.js`: 단지 + 전용면적별 실제 공급면적 평형 매핑
- `reports/supply-area-verification.md`: 매핑률과 공급면적 확인 필요 타입 목록
- `scripts/build-supply-area-map.ps1`: 실제 단지 면적 타입 조회·매핑·보고서 생성 프로그램
- `scripts/test-openapi-updater.ps1`: 현재 저장된 OpenAPI 단지 식별자를 사용하는 재시도·매칭·취소·중복·원본 보호 통합 테스트
- `scripts/transaction-first-seen.ps1`: 신규 거래 최초수집일 기록과 정정·재수집 연결 로직
- `scripts/backfill-first-seen-from-git.cjs`: Git 데이터 스냅샷을 비교해 과거 최초수집일을 안전하게 복원하는 프로그램
- `scripts/test-first-seen-tracking.ps1`: 기존 거래 초기화·신규·정정·중복·해제 처리 검증
- `scripts/test-first-seen-history-backfill.cjs`: 수집기 ID 전환·정정·해제 포함 Git 이력 복원 검증
- `scripts/test-weekly-new-transactions.cjs`: 메인페이지 최초수집일 기반 주간 필터 검증
- `scripts/check-daily-refresh-needed.ps1`, `scripts/test-refresh-gate.ps1`: 보존된 기존 갱신 판단 도구와 테스트 (현재 workflow는 pipeline의 검증된 수집 기록을 사용)
- `scripts/test-supply-area-map.mjs`: 매핑 무결성과 필수 표본 검증
- `scripts/update-data-github.ps1`: GitHub 서버용 수집·검증·저장 프로그램
- `scripts/update-pipeline.cjs`: 수집·검증·Git 저장·Pages 파일 준비·실행 결과 기록
- `scripts/write-build-meta.cjs`: 게시되는 커밋·데이터 시각·건수·해시 기록 (생성 파일은 Git에서 제외)
- `scripts/test-pages-workflow.cjs`: Pages Actions 순서·권한·공개 폴더·스케줄·중복 workflow 방지 테스트
- `.github/workflows/daily-update.yml`: 매일 07:00 KST 예약, 사람의 push, 수동 실행, Pages 배포까지 단일 workflow
- `reports/automation-reliability.md`: 안전장치와 이전·검증 기록

workflow 권한은 `contents: write`, `pages: write`, `id-token: write`이며, 기존 수집 진단 재사용을 위해 `actions: read`도 유지합니다. API 키는 `MOLIT_API_KEY` Secret 하나를 사용합니다. `pipeline-diagnostics-실행번호` artifact에 단계별 `report.json`과 수집 시 `api-log.json`, 게시 준비 시 `expected-meta.json`을 14일간 남깁니다.

API 키, 비밀번호, 개인 PC 경로, 로그, 백업, 임시파일은 저장소에 포함하지 않습니다.
