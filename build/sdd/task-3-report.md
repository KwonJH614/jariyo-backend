# Task 3 보고서: PowerShell 실행기와 사용 문서

## 개요

확정된 Task 1 Compose/fixture와 Task 2 k6 시나리오를 반복 실행하는 `run.ps1`을 추가했다. 러너는 현재 디렉터리와 무관하게 `$PSScriptRoot`에서 경로를 계산하고, Single/Dual/All마다 새 PostgreSQL 볼륨을 사용하며, 고정 Compose 프로젝트 `jariyo-issue-57` 외의 Docker 자원을 정리하지 않는다.

실제 컨테이너 기동과 부하는 Task 4 컨트롤러 범위로 남겼다. 이 Task에서는 순수 함수 focused test, PowerShell parser, base/dual Compose config, Gradle 전체 테스트만 실행했다.

## 변경 파일

- `load-tests/issue-57/run.ps1`: 의존성 확인, RSA-2048 환경키 생성·복원, 범위 제한 Compose 수명주기, local k6, stats·로그·DB 무결성·피크 RPS 증거 수집을 수행한다.
- `load-tests/issue-57/run.tests.ps1`: 외부 의존성 없이 러너의 순수 동작 6개 그룹을 검증한다.
- `load-tests/issue-57/README.md`: 전제 조건, 구성, 명령, 임계값, 산출물, 판정과 AWS 근사 한계를 설명한다.
- `build/sdd/task-3-report.md`: 본 보고서다.

`results/`는 기존 `.gitignore`와 `.dockerignore`에 이미 포함되어 있어 ignore 규칙은 변경하지 않았다. 애플리케이션, Compose, fixture, k6 시나리오, 의존성, API, schema, `jariyo-docs`는 변경하지 않았다.

## 정확한 명령 계약

```powershell
.\load-tests\issue-57\run.ps1
.\load-tests\issue-57\run.ps1 -Mode All
.\load-tests\issue-57\run.ps1 -Mode Single
.\load-tests\issue-57\run.ps1 -Mode Dual
```

- 기본값 `All`은 Single을 실행한 뒤 Dual을 실행한다.
- 각 모드는 `load-tests/issue-57/results/<yyyyMMdd-HHmmssfff>-<single|dual>/`를 만든다.
- Single은 `compose.yaml`, Dual은 `compose.yaml`과 `compose.dual.yaml`을 순서대로 사용한다.
- 시작 전과 `finally` 정리는 명시적 프로젝트 `jariyo-issue-57`에 대한 `docker compose ... down -v --remove-orphans`뿐이다.
- `up -d --build --wait --wait-timeout 240` 성공 뒤 `/fixtures/issue-57.sql`을 `ON_ERROR_STOP=1`로 적용한다.
- 고정 `+09:00` 기준 이틀 뒤 14:00/15:00을 각각 Base/Stressed로 전달한다.
- k6는 `http://localhost:8080`만 호출하며 raw JSON과 요약을 결과 디렉터리에 쓴다.
- k6 threshold exit가 0이 아니어도 피크 RPS, 무결성, 로그를 계속 수집하고 전체 종료 코드는 실패로 유지한다.
- Base/Stressed의 exact store/staff/instant에 `CONFIRMED`가 각각 1건이 아니거나 Dual access log에 두 upstream이 모두 없으면 실패한다.
- stats는 현재 Compose 프로젝트의 `ps -q` 결과만 대상으로 하고, 러너가 시작한 PID만 중지한다.

## 실행 명령

```powershell
& 'load-tests\issue-57\run.tests.ps1'
```

```powershell
$tokens=$null
$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path 'load-tests\issue-57\run.ps1'),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
```

```powershell
docker compose -f load-tests/issue-57/compose.yaml config --quiet
docker compose -f load-tests/issue-57/compose.yaml -f load-tests/issue-57/compose.dual.yaml config --quiet
```

```powershell
.\gradlew.bat test
```

## RED/GREEN 증거

### RED

`run.tests.ps1`을 먼저 만들고 아직 `run.ps1`이 없는 상태에서 실행했다. exit 1이며 의도한 누락 함수에서 실패했다.

```text
runner function is missing: Get-Issue57ComposeFiles
```

### GREEN

최소 순수 함수 구현 뒤 같은 스크립트를 실행했다. exit 0이다.

```text
PASS: 6 focused runner behavior groups
```

검증 그룹은 다음을 포함한다.

- Single/Dual Compose 파일 선택
- 임의 offset 입력을 고정 `+09:00`으로 바꾼 뒤 이틀 뒤 14:00/15:00 생성
- `http_reqs`, `attempt=initial`, Base/Stressed만 scenario/초 단위 집계
- 두 슬롯 모두 `confirmed_count=1`일 때만 무결성 통과
- cleanup의 고정 프로젝트와 `down -v --remove-orphans`, `prune` 부재
- 실제 RSA-2048의 X.509/PKCS#8 PEM header, literal `\n`, 개인키 출력 부재

## 테스트 결과

- focused test: exit 0, `PASS: 6 focused runner behavior groups`
- PowerShell parser: exit 0, `PASS: PowerShell parser validation (0 errors)`
- base Compose config: exit 0
- dual Compose config: exit 0
- Gradle 전체 테스트: exit 0, `BUILD SUCCESSFUL in 1s`, `4 actionable tasks: 4 up-to-date`
- `git diff --check`: exit 0

Compose config 중 sandbox 사용자의 `C:\Users\madog\.docker\config.json` 접근 거부 warning이 출력됐지만 base/dual 해석은 모두 exit 0이었다. 컨테이너는 시작하지 않았다.

## 이슈

- 실제 Docker Desktop의 빌드·health wait·fixture·stats·k6·무결성·Dual 분배·정리 수명주기는 Task 4에서 검증해야 한다.
- 로컬 Docker Desktop 결과는 Fargate/RDS와 동일한 절대 성능을 보장하지 않는다.
- 최종 커밋 SHA는 이 보고서를 포함한 커밋 생성 후 확정되므로 완료 메시지와 Git log에서 전달한다.

## 후속 작업

- Task 4 컨트롤러가 `-Mode Single`, `-Mode Dual` 실제 실행 결과를 확인한다.
- 실제 측정 산출물을 근거로 최종 `reports/WK_20260821-동시예약충돌부하테스트.md`를 작성한다.

## cleanup 안전성 셀프리뷰

- `docker`, Compose, Docker Engine, local k6를 확인한 뒤에만 환경값·결과 디렉터리를 변경한다.
- cleanup 인자는 Compose 파일, `--project-name jariyo-issue-57`, `down -v --remove-orphans`로 고정했다.
- 전역 prune, 다른 컨테이너·볼륨 제거, 이름 또는 glob 기반 광역 Stop/Remove 명령이 없다.
- stats 대상은 이 프로젝트의 현재 container ID 목록이며 중지는 보관한 단일 PID에만 적용한다.
- 로그 수집 또는 stats 중지 예외가 나도 중첩 `finally`에서 cleanup을 시도한다.
- cleanup 실패 자체를 결과 metadata와 비정상 종료에 반영한다.
- JWT와 명시적으로 고정한 PostgreSQL 환경값은 존재 여부와 기존 값을 보관해 최외곽 `finally`에서 복원한다.
- 공개/개인 PEM은 파일과 console log에 기록하지 않는다.

## 셀프리뷰

- 격리 worktree와 `chore/reservation-conflict-load-test` branch를 확인했다.
- worktree gitlink `faf0a1ebc42fc22167c54a93c883128d2a11c85c` 기준 관련 `01-plan.md`, `02-data-model.md`, `04-api-spec.md`, `05-frontend-api-guide.md`, `06-backend-implementation-guide.md`의 동시 예약·`CONFIRMED`·멱등성·충돌 계약을 확인했다. 공개 계약을 변경하지 않아 문서 수정은 하지 않았다.
- Task 1/2 파일은 읽기 전용 계약으로 소비했고 수정하지 않았다.
- 테스트를 먼저 작성하고 의도한 RED와 GREEN을 모두 관찰했다.
- 실제 컨테이너 기동과 부하는 실행하지 않았다.
- 최종 repository WK report를 만들지 않았다.
- 남은 위험과 Task 4 후속 검증을 `이슈`, `후속 작업`에 기록했다.
