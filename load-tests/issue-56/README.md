# Issue #56 현장 대기 순번 조회 부하 테스트

같은 매장의 현장 대기 고객이 `GET /api/v1/walk-ins/{walkInId}`를 반복 조회하는 상황과 운영자 상태 변경을 함께 재현하는 로컬 부하 테스트다. k6는 항상 `http://localhost:8080`의 Nginx만 호출한다.

## 사전 요구 사항

- Docker Desktop과 Compose v2
- 로컬 k6 1.7.1 이상
- PowerShell 7
- 호스트 TCP 8080 포트
- Docker Desktop 메모리 6~8 GiB 이상 권장

Chocolatey shim이 Windows 애플리케이션 제어 정책에 차단되는 환경에서는 러너가 설치된 실제 `k6.exe`를 찾아 사용한다.

## 구성

```text
local k6 -> localhost:8080 Nginx -> api-1
                                  -> api-2  (Dual만 사용)
api-1/api-2 -> PostgreSQL 17
```

- `Single`: API 컨테이너 1대
- `Dual`: Nginx round-robin 뒤의 API 컨테이너 2대
- API 컨테이너별 제한: 1 CPU, 2 GiB
- PostgreSQL 제한: 1 CPU, 2 GiB
- Nginx 제한: 0.25 CPU, 256 MiB

## 실행

저장소 루트에서 실행한다.

```powershell
# 새 DB를 사용해 Single과 Dual을 차례로 실행
.\load-tests\issue-56\run.ps1
.\load-tests\issue-56\run.ps1 -Mode All

# 한 구성만 실행
.\load-tests\issue-56\run.ps1 -Mode Single
.\load-tests\issue-56\run.ps1 -Mode Dual
```

러너는 런타임 RSA-2048 키를 메모리에서 생성하고, API 기동 후 실제 회원가입 API로 운영자 1명과 고객 180명을 준비한다. 고객 180명은 같은 매장·서비스의 대기열에 등록되며 access token과 private key는 결과 파일에 기록하지 않는다.

각 모드는 고정 프로젝트 `jariyo-issue-56`만 `down -v --remove-orphans`로 정리한다. `All`도 Single과 Dual 사이에 볼륨을 제거하므로 두 구성은 서로 독립된 새 데이터베이스에서 실행된다.

## 시나리오와 통과 기준

| 구분 | 사용자·주기 | 목표 피크 RPS | 지연 임계값 | 5xx |
|---|---|---:|---|---:|
| Base | 40명, 사용자당 5초마다 1회 | 8~10 | p95 ≤ 500 ms, p99 ≤ 900 ms | ≤ 1% |
| Stressed | 180명, 사용자당 2초마다 1회 | 80~100 | p95 ≤ 1,200 ms, p99 ≤ 2,000 ms | ≤ 3% |

VU별 다음 polling 예정 시각을 고정해 HTTP 응답시간이 주기에 누적되지 않도록 한다. Base는 초당 8명, Stressed는 초당 90명으로 시작 시점을 분산한다.

각 부하 구간 중 운영자 API로 서로 다른 대상을 다음과 같이 변경하고 고객 상세 API에 즉시 반영되는지 확인한다.

- `WAITING -> CALLED -> CHECKED_IN`
- `WAITING -> CALLED -> SKIPPED -> WAITING`
- 마지막 순번 고객의 `waitingAhead`가 체크인 직후 감소하는지 확인
- 모든 응답에서 고객 소유권, 순번, 상태, `waitingAhead`, 등록 시점 예상 대기 시간의 의미 검증

종료 코드 0은 다음 조건을 모두 만족했다는 뜻이다.

- k6 latency·5xx·예상 밖 응답·setup·상태 반영 threshold 통과
- raw Counter 기준 Base 8~10 RPS, Stressed 80~100 RPS
- 180개 대기 행과 180개 고유 순번 유지
- 최종 활성 대기 178개, 체크인 대상 2개, 복귀 대상 2개
- 허용하지 않은 상태 이력 0개
- Dual에서 두 API upstream이 모두 현장 대기 요청을 처리
- 로그·증거 수집과 범위 제한 cleanup 성공

## 결과 파일

각 실행 결과는 `load-tests/issue-56/results/<yyyyMMdd-HHmmssfff>-<single|dual>/`에 생성되며 Git에서 제외된다.

```text
summary.json / summary.md       k6 요약과 threshold 판정
raw.json                       line-delimited raw metric
peak-rps.json / peak-rps.md    polling dispatch 초당 피크
integrity.csv                  최종 DB 정합성 증거
dual-upstreams.json            Dual 서비스별 container ID·IP
docker-stats.csv               해당 Compose 프로젝트의 자원 표본
compose.log                    Nginx/API/PostgreSQL 로그
run-metadata.json              모드, 종료 코드, 실패 사유
```

## 해석 주의

이 환경은 Docker Desktop에서 Fargate/RDS 배치의 상대 특성을 보는 근사치다. 로컬 VM, 파일 시스템과 네트워크가 AWS와 다르므로 절대 성능 또는 운영 수용량으로 간주하지 않는다. `docker-stats.csv`는 setup과 전체 시나리오를 포함하고 timestamp가 없으므로 순간 최대값을 특정 polling 구간의 사용률로 단정하지 않는다.
