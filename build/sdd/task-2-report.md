# Task 2 보고서: k6 동시 예약 충돌 시나리오

## 개요

이슈 #57의 단일/이중 API Compose 환경에서 실행할 k6 1.7.1 동시 예약 충돌 시나리오를 추가했다. 스크립트는 Nginx `BASE_URL`만 호출하고, 실제 회원가입 API로 결정적인 100명 고객 토큰을 만든 뒤 Base(20 VU)와 Stressed(100 VU)를 서로 다른 입력 슬롯에 순차 실행한다.

관련 기획·데이터 모델·API·프론트엔드 연동·백엔드 구현 문서를 검토했다. 이 작업은 애플리케이션·API·스키마 계약을 변경하지 않고 이미 문서화된 계약을 소비하는 부하 테스트만 추가하므로 `jariyo-docs` 본문 변경은 하지 않았다.

## 변경 파일

- `load-tests/issue-57/reservation-conflict.js`: 회원가입 setup, Base/Stressed 예약, 의미론적 응답 분류, 사용자 정의 지표/임계값, JSON·Markdown 요약을 정의했다.
- `build/sdd/task-2-report.md`: 본 작업 보고서다.

## Task 3 내보낸 환경 계약

- `BASE_URL`: 선택값이며 기본값은 `http://localhost:8080`이다. k6가 호출하는 유일한 대상이다.
- `BASE_START_AT`: 필수 ISO-8601 offset timestamp다. `STRESSED_START_AT`와 달라야 한다.
- `STRESSED_START_AT`: 필수 ISO-8601 offset timestamp다. `BASE_START_AT`와 달라야 한다.
- `RESULT_DIR`: 선택값이며 기본값은 `load-tests/issue-57/results/manual`이다. `handleSummary`가 이 경로에 `summary.json`, `summary.md`를 쓴다. 실행 전 디렉터리를 만들어야 한다.
- 실행 예시: `k6 run -e BASE_START_AT=... -e STRESSED_START_AT=... -e RESULT_DIR=... load-tests/issue-57/reservation-conflict.js`

## 실행 명령

```powershell
k6 inspect load-tests/issue-57/reservation-conflict.js
```

```powershell
k6 inspect -e BASE_START_AT=2026-09-07T09:00:00+09:00 -e STRESSED_START_AT=2026-09-07T10:00:00+09:00 -e RESULT_DIR=load-tests/issue-57/results/inspect load-tests/issue-57/reservation-conflict.js
```

```powershell
.\gradlew.bat test
```

## 테스트 결과

### RED: 생성 전 k6 inspect

exit 1.

```text
time="2026-08-21T11:08:08+09:00" level=error msg="The moduleSpecifier \"load-tests/issue-57/reservation-conflict.js\" couldn't be found on local disk. Make sure that you've specified the right path to the file. If you're running k6 using the Docker image make sure you have mounted the local directory (-v /local/path/:/inside/docker/path) containing your script and modules so that they're accessible by k6 from inside of the container, see https://grafana.com/docs/k6/latest/using-k6/modules/#use-modules-with-docker."
```

### GREEN: 명시 환경값 k6 inspect

exit 0.

```text
{
  "scenarios": {
    "base": {
      "executor": "per-vu-iterations",
      "exec": "baseReservation",
      "vus": 20,
      "iterations": 1,
      "maxDuration": "30s"
    },
    "stressed": {
      "executor": "per-vu-iterations",
      "startTime": "35s",
      "exec": "stressedReservation",
      "vus": 100,
      "iterations": 1,
      "maxDuration": "2m0s"
    }
  },
  "thresholds": {
    "base_reservation_duration": ["p(95) <= 1200", "p(99) <= 2000"],
    "reservation_5xx{scenario:base}": ["rate <= 0.01"],
    "reservation_5xx{scenario:stressed}": ["rate <= 0.03"],
    "reservation_conflict{scenario:base,attempt:initial}": ["count == 19"],
    "reservation_conflict{scenario:stressed,attempt:initial}": ["count == 99"],
    "reservation_conflict{scenario:stressed,attempt:retry}": ["count == 99"],
    "reservation_success{scenario:base,attempt:initial}": ["count == 1"],
    "reservation_success{scenario:stressed,attempt:initial}": ["count == 1"],
    "reservation_success{scenario:stressed,attempt:retry}": ["count == 0"],
    "reservation_unexpected{scenario:base}": ["rate == 0"],
    "reservation_unexpected{scenario:stressed}": ["rate == 0"],
    "setup_failures": ["count == 0"],
    "stressed_reservation_duration": ["p(95) <= 2500", "p(99) <= 4000"]
  }
}
```

`k6 inspect`의 전체 출력에서 나머지 전역 옵션은 `null`로 해석됐으며, 오류와 경고는 없었다.

### Gradle 전체 테스트

첫 sandbox 실행은 Gradle 9.5.1 배포본 다운로드 권한으로 exit 1이었고, 권한 승인 뒤 동일 명령을 재실행했다. 최종 실행은 exit 0이었다.

```text
> Task :compileJava UP-TO-DATE
> Task :processResources UP-TO-DATE
> Task :classes UP-TO-DATE
> Task :compileTestJava UP-TO-DATE
> Task :processTestResources NO-SOURCE
> Task :testClasses UP-TO-DATE
> Task :test UP-TO-DATE

BUILD SUCCESSFUL in 2s
4 actionable tasks: 4 up-to-date
```

## 이슈

- 실제 Compose 기동과 k6 부하는 이 Task의 범위가 아니므로 실행하지 않았다. 실제 측정 결과는 fixture 적용, 미래의 서로 다른 영업 슬롯 설정, 결과 디렉터리 생성 뒤 컨트롤러가 확인해야 한다.
- 보고서를 포함한 최종 Git 객체의 SHA는 커밋 생성 후 확정되므로 최종 SHA는 작업 완료 메시지와 Git 로그에서 확인한다.

## 후속 작업

- Task 3는 Base/dual Compose를 기동하고 fixture를 적용한 뒤 위 환경 계약으로 k6를 실행한다.
- Task 3는 raw JSON 결과의 `scenario` 및 `attempt=initial|retry` 태그로 초당 피크 RPS를 별도 산출한다.

## 셀프리뷰

- `setup()`은 `issue57-001@example.com`부터 `issue57-100@example.com`까지 정확히 100개의 서로 다른 요청을 10개 고정 배치로 보내고, 유효하지 않은 JSON 또는 `data.accessToken` 누락을 포함한 모든 signup 실패를 `setup_failures`에 1회씩 기록한다.
- 각 VU는 scenario 전역 iteration 번호를 100개 token 배열에 매핑한다. Base와 Stressed에서 각각 20/100개의 고유 token을 사용하며, Stressed 100 VU는 전체 100개 token을 한 번씩 사용한다.
- 예약 HTTP 시도마다 semantic `201` 또는 정확한 `409`/`RESERVATION_SLOT_ALREADY_TAKEN`만 기대 응답으로 처리한다. 모든 시도는 5xx·unexpected Rate에 정확히 한 번 기록하고, duration은 Base 또는 Stressed Trend에 정확히 한 번 기록한다.
- Stressed의 `201` 이외 모든 초기 결과는 1초 뒤 같은 body·Authorization·`Idempotency-Key`로 정확히 한 번 재시도한다. retry는 관측용 `attempt=retry` 태그만 달라진다.
- setup HTTP에는 `phase=setup`만 태그를 붙이고 예약 사용자 정의 지표에는 추가하지 않았다. 예약 초기/재시도 HTTP에는 raw JSON RPS 분리용 `scenario`, `attempt` 태그를 붙였다.
- 사용자 정의 Counter와 tagged threshold는 Base 1/19, Stressed initial 1/99, retry 0/99의 정확한 cardinality를 강제한다. `handleSummary`는 machine-readable JSON, 시나리오 카운트·p95/p99·5xx/unexpected·threshold pass/fail을 담는 Markdown을 출력한다.
- 애플리케이션, Compose, fixture, 의존성, API, schema는 변경하지 않았다. `k6 inspect` RED/GREEN 및 `./gradlew.bat test` 성공을 확인했다.

## 리뷰 수정 1차

- 원 Task 2 커밋 SHA: `2e45485956e62bf9eea6d55c24a5d65bc53c046b`
- `options.summaryTrendStats`에 `p(95)`, `p(99)`를 명시해 `handleSummary()`가 사용하는 Trend 값이 항상 k6 summary data에 포함되도록 했다.
- timestamp 파서는 정규식만 통과시키는 `Date.parse()` 대신 월별 일수·윤년·시/분/초·Java `ZoneOffset` 호환 최대 `±18:00`를 검증한다. fractional second는 최대 9자리 nanosecond로 보존하고, offset을 뺀 instant의 초·nanosecond를 비교해 표현이 달라도 같은 instant인 두 슬롯을 거절한다.

### 리뷰 수정 검증 명령과 출력

```powershell
k6 inspect -e BASE_START_AT=2026-09-07T09:00:00+09:00 -e STRESSED_START_AT=2026-09-07T10:00:00+09:00 -e RESULT_DIR=load-tests/issue-57/results/inspect load-tests/issue-57/reservation-conflict.js
k6 inspect -e BASE_START_AT=2026-09-07T09:00:00+09:00 -e STRESSED_START_AT=2026-09-07T00:00:00Z load-tests/issue-57/reservation-conflict.js
k6 inspect -e BASE_START_AT=2026-02-30T09:00:00+09:00 -e STRESSED_START_AT=2026-09-07T10:00:00+09:00 load-tests/issue-57/reservation-conflict.js
```

```text
valid inspect: exit 0
"summaryTrendStats": [
  "p(95)",
  "p(99)"
]

same-instant inspect: exit 107
Error: BASE_START_AT and STRESSED_START_AT must be different slots

invalid-date inspect: exit 107
Error: BASE_START_AT must be an ISO-8601 offset timestamp

valid=0 sameInstant=107 invalidDate=107
```

서로 다른 문자열 `2026-09-07T09:00:00+09:00`와 `2026-09-07T00:00:00Z`는 같은 instant이므로 거절됐고, 존재하지 않는 `2026-02-30`도 거절됐다.
