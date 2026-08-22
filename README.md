# 서울·부산 주요 아파트 실거래가

서울·부산 136개 주요 아파트의 실거래 데이터를 실제 공급면적 평형 기준으로 보여주는 정적 웹사이트입니다. 국토교통부 원본 전용면적㎡는 그대로 보존하고, 단지별 실제 면적 타입과 일치시킨 공급면적 평형을 화면·필터·그래프에 사용합니다. Netlify는 저장소의 `public/` 폴더만 배포합니다.

## 자동갱신

GitHub Actions의 `Daily apartment transaction update` workflow가 한국시간 매일 오전 7시 17분과 8시 17분에 실행됩니다. 두 번째 실행은 첫 실행 실패 시 복구용이며, 데이터 변경이 없으면 커밋하지 않습니다. GitHub의 **Actions** 화면에서 `Run workflow`를 눌러 수동 실행할 수도 있습니다.

갱신 순서:

1. GitHub Repository Secret `MOLIT_API_KEY`로 국토교통부 공식 실거래가 OpenAPI 호출
2. 41개 법정동 지역코드의 최근 6개월을 월별로 재조회
3. 단지명·법정동·지번·전용면적·기존 거래를 대조해 136개 단지를 정확히 매칭
4. 신규·취소·정정·늦은 신고 반영 및 중복 제거
5. 날짜·필수값·단지 수·거래 수 급감 여부 검증
6. 모든 API 호출과 검증이 성공한 경우에만 `public/data/transactions.js`를 원자적으로 교체
7. 거래가 바뀌면 저장된 실제 단지 타입 자료로 공급면적 매핑과 확인 필요 보고서를 다시 생성·검증
8. 실제 데이터가 바뀐 경우에만 거래 원본·공급면적 매핑·보고서를 `main`에 commit/push
9. 기존 Netlify Git 연동이 `public/` 폴더를 자동 배포하고 공개 데이터 해시를 재검증

조회 또는 검증에 실패하면 기존 데이터 파일은 변경하지 않으며 commit/push도 실행되지 않습니다.

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
- `scripts/test-openapi-updater.ps1`: OpenAPI 재시도·단지 매칭·취소·중복·원본 보호 통합 테스트
- `scripts/test-supply-area-map.mjs`: 매핑 무결성과 필수 표본 검증
- `scripts/update-data-github.ps1`: GitHub 서버용 수집·검증·저장 프로그램
- `.github/workflows/daily-update.yml`: 매일 오전 7시 17분·8시 17분 및 수동 실행 설정
- `netlify.toml`: Netlify 공개 폴더 설정

API 키, 비밀번호, 개인 PC 경로, 로그, 백업, 임시파일은 저장소에 포함하지 않습니다.
