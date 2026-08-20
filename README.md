# 서울·부산 주요 아파트 실거래가

서울·부산 134개 주요 아파트의 실거래 데이터를 보여주는 정적 웹사이트입니다. Netlify는 저장소의 `public/` 폴더만 배포합니다.

## 자동갱신

GitHub Actions의 `Daily apartment transaction update` workflow가 한국시간 매일 오전 7시에 실행됩니다. GitHub의 **Actions** 화면에서 `Run workflow`를 눌러 수동 실행할 수도 있습니다.

갱신 순서:

1. 국토교통부 실거래가 공개시스템 화면에 접속
2. 현재 연도와 직전 연도를 134개 단지별로 재조회
3. 신규·취소·정정 거래 반영 및 신고번호 중복 제거
4. 날짜·필수값·단지 수·거래 수 급감 여부 검증
5. 모든 검증이 성공한 경우에만 `public/data/transactions.js`를 원자적으로 교체
6. 실제 거래 데이터가 바뀐 경우에만 `main`에 commit/push
7. 기존 Netlify Git 연동이 `public/` 폴더를 자동 배포

조회 또는 검증에 실패하면 기존 데이터 파일은 변경하지 않으며 commit/push도 실행되지 않습니다.

## 데이터 소스

- 국토교통부 실거래가 공개시스템: `https://rt.molit.go.kr/`
- 단지·연도 조회 화면 내부 주소: `https://rt.molit.go.kr/pt/gis/ptDtl.do`

이 주소는 공개 웹 화면에서 사용하는 내부 조회 주소이며 별도 API 키가 필요하지 않습니다. 주소 접근이 차단되거나 응답 형식이 변경되면 workflow는 실패로 종료하며 임의 데이터나 샘플 데이터로 대체하지 않습니다.

## 저장소 구조

- `public/`: Netlify가 배포하는 홈페이지 파일
- `public/data/transactions.js`: 검증된 공개 실거래 데이터
- `scripts/update-data-github.ps1`: GitHub 서버용 수집·검증·저장 프로그램
- `.github/workflows/daily-update.yml`: 매일 오전 7시 및 수동 실행 설정
- `netlify.toml`: Netlify 공개 폴더 설정

API 키, 비밀번호, 개인 PC 경로, 로그, 백업, 임시파일은 저장소에 포함하지 않습니다.
