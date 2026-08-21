# Task 1 보고서: 서버 컨테이너 환경

## 개요

이슈 #57의 동시 예약 부하 테스트를 위한 독립 Compose 환경을 `load-tests/issue-57/`에 추가했다. 기본 구성은 PostgreSQL 17, API 1대, Nginx이며, dual override는 API 2대를 Nginx 기본 round-robin upstream으로 연결한다. 호스트에는 Nginx의 `8080`만 공개한다.

공개 매장 조회 API `GET /api/v1/stores`를 API health check로 사용했다. 기존 `RsaKeyParser`가 literal `\\n`을 실제 개행으로 정규화하므로 Compose는 `JWT_PUBLIC_KEY`, `JWT_PRIVATE_KEY` 값을 그대로 컨테이너 환경에 전달한다.

## 변경 파일

- `.dockerignore`: 루트 Docker build context에서 Git/Gradle 산출물과 부하 테스트 런타임 산출물을 제외했다.
- `.gitignore`: 부하 테스트 키, 로그, 결과, 로컬 볼륨 경로를 추적 대상에서 제외했다.
- `load-tests/issue-57/Dockerfile`: Gradle wrapper로 bootJar를 만드는 Java 17 multi-stage 이미지다.
- `load-tests/issue-57/compose.yaml`: PostgreSQL 17, API 1, Nginx 기본 스택이다.
- `load-tests/issue-57/compose.dual.yaml`: API 2와 dual Nginx 설정을 추가하는 override다.
- `load-tests/issue-57/nginx/default.conf`: API 1 단일 upstream 설정이다.
- `load-tests/issue-57/nginx/default.dual.conf`: API 1/API 2 기본 round-robin upstream 설정이다.
- `load-tests/issue-57/fixture.sql`: seed 매장을 이용하는 결정적 부하 테스트 fixture다.
- `build/sdd/task-1-report.md`: 본 보고서다.

## 설계 결정

- API와 PostgreSQL에 각각 `cpus: "1.0"`, `mem_limit: 2g`를 적용했다. Nginx는 독립적으로 `0.25 CPU`, `256m`을 적용했다.
- PostgreSQL health check는 `pg_isready`를 사용하고, API health check는 Actuator 없이 `wget http://localhost:8080/api/v1/stores`를 호출한다.
- fixture SQL은 `psql -f /fixtures/issue-57.sql`로 Flyway 완료 뒤 실행할 수 있도록 PostgreSQL에 읽기 전용으로 마운트한다.
- fixture의 고정 ID는 매장 `00000000-0000-7000-8000-000000000001`, 서비스 `00000000-0000-7000-8000-000000000401`, 직원 `00000000-0000-7000-8000-000000000301`이다. 서비스는 ACTIVE, 30분 서비스/10분 정리 시간이며, ACTIVE 예약 가능 직원·활성 담당 서비스·7일 영업/근무 시간을 모두 생성한다.
- Nginx access log format에 `upstream=$upstream_addr`를 넣어 dual 분배 결과를 감사할 수 있게 했다. 부하 분배 알고리즘 지시문을 추가하지 않아 Nginx 기본 round-robin을 사용한다.
- 고정 local volume `jariyo-issue-57-postgres-data`를 사용하며 PostgreSQL/API 포트는 호스트에 공개하지 않는다.

## 실행 명령

```powershell
$required = @('load-tests/issue-57/Dockerfile', 'load-tests/issue-57/compose.yaml', 'load-tests/issue-57/compose.dual.yaml', 'load-tests/issue-57/nginx/default.conf', 'load-tests/issue-57/nginx/default.dual.conf', 'load-tests/issue-57/fixture.sql')
$missing = $required | Where-Object { -not (Test-Path $_) }
if ($missing.Count -eq $required.Count) { Write-Error ('RED: required load-test files are missing: ' + ($missing -join ', ')); exit 1 }
```

```powershell
docker compose -f load-tests/issue-57/compose.yaml config
docker compose -f load-tests/issue-57/compose.yaml -f load-tests/issue-57/compose.dual.yaml config
.\gradlew.bat test
```

추가 정적 검증은 `docker compose ... config --format json` 출력을 PowerShell 객체로 읽어 base/dual topology, CPU·메모리, 포트 공개, fixture read-only mount, Nginx 설정 교체를 확인했다. `git check-ignore`로 키·로그·결과·볼륨 경로도 확인했다. 컨테이너는 시작하지 않았다.

## 테스트 결과

- RED 검증: exit 1. `RED: required load-test files are missing: load-tests/issue-57/Dockerfile, load-tests/issue-57/compose.yaml, load-tests/issue-57/compose.dual.yaml, load-tests/issue-57/nginx/default.conf, load-tests/issue-57/nginx/default.dual.conf, load-tests/issue-57/fixture.sql`
- base Compose: exit 0. `api-1`, `postgres`는 `cpus: 1`, `mem_limit: "2147483648"`; Nginx만 `published: "8080"`; fixture target은 `/fixtures/issue-57.sql`, `read_only: true`로 해석됐다.
- dual Compose: exit 0. `api-2`가 추가되고 Nginx mount source가 `nginx/default.dual.conf`로 해석됐으며 API 1/API 2가 모두 PostgreSQL health check에 의존한다.
- Compose 계약 검증: exit 0. `PASS: base/dual topology, limits, port exposure, fixture mount, and Nginx override match the task brief`
- 런타임 산출물 ignore 검증: exit 0. `PASS: generated keys, logs, results, and local volumes are ignored`
- Gradle 테스트: exit 0. `BUILD SUCCESSFUL in 4s`, `4 actionable tasks: 4 up-to-date`.

`docker compose config`는 exit 0이었고 Docker 사용자 설정 파일 접근 제한 때문에 `WARNING: Error loading config file: open C:\\Users\\madog\\.docker\\config.json: Access is denied.` 경고를 두 번 출력했다. 정적 Compose 해석 결과에는 영향을 주지 않았다.

## 이슈

Docker engine pipe 접근 권한이 없어 실제 이미지 build, Nginx runtime syntax 검사, 컨테이너 기동은 수행하지 않았다. 이는 brief의 "컨테이너를 시작하지 말 것" 제약에도 맞으며 실제 실행은 컨트롤러가 수행한다.

## 후속 작업

컨트롤러는 Flyway 완료 후 `docker compose exec -T postgres psql -U jariyo -d jariyo -f /fixtures/issue-57.sql`로 fixture를 적용하고, 제공할 JWT 키와 k6 runner를 사용해 base/dual 부하 테스트를 실행한다.

## 셀프리뷰

- 관련 기획·데이터 모델·API·백엔드 문서를 확인했고, 이 작업은 공개 API·스키마·애플리케이션 동작을 변경하지 않아 문서 본문 수정은 필요하지 않았다.
- Java 변경이 없고 YAML/Nginx/SQL에는 관례적 공백 들여쓰기를 사용했다.
- Actuator, Redis, Worker, 의존성, migration, 애플리케이션 코드를 추가하지 않았다.
- 생성 키·원시 결과·로그·볼륨은 `.gitignore`와 `.dockerignore`에서 제외했다.
- base/dual Compose 정적 검증과 전체 Gradle 테스트를 실행했으며, 컨테이너는 시작하지 않았다.
- 최초 환경 추가 커밋 SHA: `3b65376dcb05f44bf37ae8d5ddcafd2ecd29f85d`

## 리뷰 수정 검증

리뷰 1차 수정으로 `.dockerignore`에 `load-tests/**/volumes`를 추가했다.

```powershell
$dockerIgnore = Get-Content '.dockerignore'; $volumePath = 'load-tests/issue-57/volumes/postgres-data/PG_VERSION'; if ($dockerIgnore -notcontains 'load-tests/**/volumes') { throw 'Docker build context does not exclude local volumes' }; if ($volumePath -notmatch '^load-tests/.+/volumes(?:/|$)') { throw 'Focused volume path does not match the Docker ignore rule' }; git -c safe.directory='C:/Projects/jariyo-backend/build/worktrees/chore-reservation-conflict-load-test' check-ignore -q $volumePath; if ($LASTEXITCODE -ne 0) { throw 'Git does not ignore the local volume path' }; if ($dockerIgnore -contains 'load-tests/issue-57/Dockerfile') { throw 'Dockerfile must remain in the build context' }; Write-Output 'PASS: local volume path is ignored by Git and excluded from the Docker build context; Dockerfile remains included'
```

정확한 출력:

```text
warning: unable to access 'C:\Users\madog/.config/git/ignore': Permission denied
PASS: local volume path is ignored by Git and excluded from the Docker build context; Dockerfile remains included
```
