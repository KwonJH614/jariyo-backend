# Issue #57 동시 예약 충돌 부하 테스트

동일 직원·동일 시간대에 예약 요청이 몰릴 때 정확히 한 건만 `CONFIRMED`가 되는지 확인하는 로컬 재현 환경이다. k6는 항상 `http://localhost:8080`의 Nginx만 호출한다.

## 사전 요구 사항

- Docker Desktop 실행 및 Compose v2 사용 가능
- Docker Desktop 메모리 6~8 GiB 이상 할당 권장
- 로컬 `k6` 1.7.1 이상
- 호스트 TCP 8080 포트 사용 가능
- PowerShell 7과 Java 17 프로젝트 빌드에 필요한 네트워크/Gradle 캐시

Docker 내부에서는 PostgreSQL 5432와 API 8080을 사용하지만 호스트에는 Nginx 8080만 공개한다.

## 구성

```text
local k6 -> localhost:8080 Nginx -> api-1
                                  -> api-2  (Dual만 사용)
api-1/api-2 -> PostgreSQL 17
```

- `Single`: Nginx 뒤에 API 컨테이너 1대
- `Dual`: Nginx 기본 round-robin 뒤에 API 컨테이너 2대
- API 컨테이너별 제한: 1 CPU, 2 GiB
- PostgreSQL 제한: 1 CPU, 2 GiB
- Nginx 제한: 0.25 CPU, 256 MiB

## 실행

저장소 루트에서 다음 중 하나를 실행한다. 러너 내부 경로는 모두 `$PSScriptRoot`에서 계산하므로 다른 현재 디렉터리에서도 `run.ps1`의 절대 경로로 실행할 수 있다.

```powershell
# Single 실행 후 새 DB로 Dual 실행
.\load-tests\issue-57\run.ps1
.\load-tests\issue-57\run.ps1 -Mode All

# 한 구성만 실행
.\load-tests\issue-57\run.ps1 -Mode Single
.\load-tests\issue-57\run.ps1 -Mode Dual
```

실행 전에 `docker`, Docker Engine, Compose, 로컬 `k6` 사용 가능 여부를 확인한다. 런타임에 RSA-2048 키를 메모리에서 생성해 X.509 공개 키와 PKCS#8 개인 키를 literal `\n` 환경값으로 전달하며 키를 파일이나 콘솔에 기록하지 않는다. 호출자가 설정한 JWT 및 PostgreSQL 관련 환경값은 실행 후 복원한다.

각 모드는 고정 프로젝트 `jariyo-issue-57`만 `down -v --remove-orphans`로 정리한 뒤 빌드·기동한다. Compose health check가 최대 240초 안에 성공한 다음 fixture를 적용하고 부하를 시작한다. `All`도 Single과 Dual 사이에 볼륨을 제거하므로 각 모드는 새 데이터베이스를 사용한다.

## 시나리오와 통과 기준

테스트 날짜는 실행 시점의 고정 `+09:00` 달력 날짜에서 이틀 뒤이며 Base는 14:00, Stressed는 15:00 슬롯을 사용한다.

| 구분 | 요청 | 기대 결과 | 지연 임계값 | 5xx |
|---|---:|---|---|---:|
| Base | 동시 고객 20명, 각 1회 | initial `201` 1건, 유효한 `409` 19건 | p95 ≤ 1,200 ms, p99 ≤ 2,000 ms | ≤ 1% |
| Stressed | 동시 고객 100명, 각 1회 | initial `201` 1건, 유효한 `409` 99건 | p95 ≤ 2,500 ms, p99 ≤ 4,000 ms | ≤ 3% |

Stressed의 initial `201` 이외 응답은 1초 뒤 같은 `Idempotency-Key`로 한 번 재시도한다. retry에서는 성공 0건, 유효한 충돌 99건을 기대한다. setup 실패와 예상 밖 응답은 0이어야 한다.

종료 코드 0은 다음 조건을 모두 만족했다는 뜻이다.

- Compose 시작, fixture 적용, k6 임계값, raw JSON 피크 분석 성공
- Base와 Stressed의 정확한 매장·직원·시각에 `CONFIRMED` 예약이 각각 정확히 1건
- Dual일 때 scoped Compose로 찾은 `api-1`/`api-2` 컨테이너의 프로젝트 네트워크 `IP:8080`이 Nginx access log에 모두 존재
- 로그·증거 수집과 해당 Compose 프로젝트 정리 성공

k6 임계값이 실패해도 무결성 조회와 로그 수집은 계속하며, 마지막 프로세스 종료 코드는 실패로 유지된다.

## 결과 파일

각 실행은 `load-tests/issue-57/results/<yyyyMMdd-HHmmssfff>-<single|dual>/`에 보존된다.

```text
summary.json / summary.md       k6 요약과 threshold 판정
raw.json                       k6 line-delimited raw metric
peak-rps.json / peak-rps.md    initial 요청만 집계한 Base/Stressed 초당 피크
integrity.csv                  정확한 두 슬롯의 DB 무결성 증거
dual-upstreams.json            Dual 서비스별 container ID·project-network IP 증거
docker-stats.csv               현재 프로젝트 컨테이너 ID만 수집한 자원 표본
compose.log                    Nginx/API/PostgreSQL 로그
k6.*.log                       k6 표준 출력·오류
fixture.*.log                  fixture 적용 출력·오류
compose-up.*.log               Compose 시작 출력·오류
pre-cleanup.*.log              실행 전 범위 제한 정리 출력·오류
cleanup.*.log                  실행 후 범위 제한 정리 출력·오류
run-metadata.json              모드, 슬롯, 종료 코드, 실패 사유
```

`docker-stats.csv`의 열 순서는 컨테이너 ID, 이름, CPU, 메모리, 네트워크 I/O, 블록 I/O, PID 수다. 생성 결과는 Git ignore 대상이다.

## 정리 범위와 해석 주의

러너는 전역 Docker prune이나 다른 프로젝트의 컨테이너·볼륨 삭제를 하지 않는다. 시작 전과 `finally`에서 Compose 파일과 명시적 프로젝트명 `jariyo-issue-57`을 사용한 `down -v --remove-orphans`만 실행한다. stats 수집은 해당 프로젝트의 현재 컨테이너 ID로 제한하고, 종료할 때도 보관한 Process 객체의 `Kill()`과 제한 시간 대기만 사용한다.

이 환경은 Fargate/RDS 배치의 동시성·경합 양상을 재현하기 위한 근사치다. Docker Desktop의 VM, 호스트 자원, 파일 시스템과 네트워크 특성이 AWS와 다르므로 절대 성능 수치를 Fargate/RDS 성능과 동일하게 해석하면 안 된다.
