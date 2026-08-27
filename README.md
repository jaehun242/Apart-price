# 서울·부산 주요 아파트 실거래가

서울·부산 136개 주요 아파트의 실거래 데이터를 실제 공급면적 평형 기준으로 보여주는 정적 웹사이트입니다. 국토교통부 원본 전용면적㎡는 그대로 보존하고, 단지별 실제 면적 타입과 일치시킨 공급면적 평형을 화면·필터·그래프에 사용합니다. Netlify는 저장소의 `public/` 폴더만 배포합니다.

## 자동갱신

GitHub Actions의 `Daily apartment transaction update` workflow가 한국시간 매일 06:37, 09:23, 12:41, 16:07, 19:29, 22:53에 실행을 시도합니다. 당일 성공 실행이 있으면 후속 예약은 국토부 API를 다시 호출하지 않고 정상 종료하며, 실패했거나 GitHub 예약이 누락된 경우 다음 시간대가 자동 복구를 시도합니다. 데이터 변경이 없으면 커밋하지 않습니다. GitHub Actions 실행 이력 확인에 일시적으로 실패하면 갱신을 생략하지 않고 실제 업데이트를 실행합니다. **Actions** 화면의 `Run workflow`를 누른 수동 실행은 당일 성공 여부와 관계없이 항상 실행됩니다.

갱신 순서:

1. GitHub Repository Secret `MOLIT_API_KEY`로 국토교통부 공식 실거래가 OpenAPI 호출
2. 41개 법정동 지역코드의 최근 6개월을 월별로 재조회
3. 단지명·법정동·지번·전용면적·기존 거래를 대조해 136개 단지를 정확히 매칭
4. 기존 `transactionId`와 안정적인 거래 추적키를 함께 비교해 신규·취소·정정·늦은 신고 반영 및 중복 제거
5. 처음 발견한 신규 거래에만 한국 날짜 `first_seen_at`을 기록하고, 정정·재수집 거래는 기존 최초수집일 유지
6. 날짜·필수값·단지 수·거래 수 급감 여부 검증
7. 모든 API 호출과 검증이 성공한 경우에만 `public/data/transactions.js`를 원자적으로 교체
8. 거래가 바뀌면 저장된 실제 단지 타입 자료로 공급면적 매핑과 확인 필요 보고서를 다시 생성·검증
9. 실제 데이터가 바뀐 경우에만 거래 원본·공급면적 매핑·보고서를 `main`에 commit/push
10. 기존 Netlify Git 연동이 `public/` 폴더를 자동 배포하고 공개 데이터 해시를 재검증

조회 또는 검증에 실패하면 기존 데이터 파일은 변경하지 않으며 commit/push도 실행되지 않습니다.

메인페이지의 **이번 주 신규 실거래**는 실제 계약일이 아니라 `first_seen_at`(우리 시스템의 최초 수집일)로 집계합니다. 가격 그래프·시세 계산·기간별 통계와 거래 카드에 표시하는 계약일은 계속 실제 계약일 기준입니다. 추적 도입 전 기존 거래는 `first_seen_at: null`로 초기화해 도입 주에 신규 거래로 잘못 집계되지 않도록 했습니다.

최초 추적 도입 주(2026-08-24 시작)는 Git의 월요일 직전 데이터와 8월 26·27일 자동수집 스냅샷을 거래 추적키로 비교해 복원했습니다. 수집기 전환으로 바뀐 거래 ID는 기존 거래로 연결하고, 당시 처음 등장했으며 현재도 유효한 105건만 실제 최초 등장일을 기록했습니다. 거래별 근거는 `reports/weekly-first-seen-backfill-2026-08-24.md`에 보존합니다.

## 데이터 소스

- 국토교통부 아파트 매매 실거래가 상세자료 공식 OpenAPI: `https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev`
- 실제 단지 공급/전용 면적 타입: 아실 단지정보 `https://asil.kr/app/apt_info.jsp`

OpenAPI 키는 코드나 로그에 저장하지 않고 GitHub Actions의 `secrets.MOLIT_API_KEY`로만 전달합니다. API 접근이 차단되거나 응답·단지 매칭·검증에 실패하면 workflow는 실패로 종료하며 기존 데이터는 유지하고 임의 데이터나 샘플 데이터로 대체하지 않습니다.

## 저장소 구조

- `public/`: Netlify가 배포하는 홈페이지 파일
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
- `scripts/check-daily-refresh-needed.ps1`: 당일 성공 이력을 확인해 중복 API 호출을 막고 실패 시 후속 예약을 허용하는 프로그램
- `scripts/test-refresh-gate.ps1`: 당일 성공·실패·수동 실행에 대한 자동 갱신 판단 테스트
- `scripts/test-supply-area-map.mjs`: 매핑 무결성과 필수 표본 검증
- `scripts/update-data-github.ps1`: GitHub 서버용 수집·검증·저장 프로그램
- `.github/workflows/daily-update.yml`: 하루 6회 분산 예약·당일 중복 방지·수동 실행 설정
- `netlify.toml`: Netlify 공개 폴더 설정

API 키, 비밀번호, 개인 PC 경로, 로그, 백업, 임시파일은 저장소에 포함하지 않습니다.
