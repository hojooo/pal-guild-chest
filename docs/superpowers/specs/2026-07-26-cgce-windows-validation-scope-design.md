# CGCE Windows 검증 범위 분리 설계

- 상태: 승인됨
- 작성일: 2026-07-26
- 대상: Task 11A Windows Discovery 검증과 Gate A 이후 기능 수용 검증
- 선행 설계:
  `docs/superpowers/specs/2026-07-24-cgce-windows-discovery-runbook-design.md`
- 구현 계획:
  `docs/superpowers/plans/2026-07-26-cgce-windows-validation-fixes.md`
- 운영 문서: `docs/windows-discovery-operator-runbook.md`

## 배경

Windows PowerShell `5.1`에서 이전 source의
`tests/windows/Run-CgceDiscoveryTests.ps1`를 실행한 결과는 총 174개 중
100개 통과, 74개 실패였으며 마지막 줄은
`CGCE_WINDOWS_TESTS failures=74`였다. 이 suite는 contract, filesystem,
runtime, lifecycle 세부 회귀를 모두 포함하므로 운영자가 매 점검 전에 판단할
최소 검증보다 범위가 넓다.

동시에 운영 Palworld 서버가 UDP `8211`을 정상 사용하고 있다. 실제 포트를
synthetic test의 고정 입력으로 사용하면 운영 서버가 정상 실행 중이라는 이유로
합성 검증이 실패한다. 반대로 실제 maintenance에서 listener 검사를 제거하면
production과 test clone이 동시에 같은 포트를 사용할 수 있어 안전 경계가
약해진다.

현재 Task 11A 도구는 read-only Discovery 전용이다. Gate A 이전에는 실제
길드 상자 슬롯을 늘리는 mutation을 포함하지 않는다.

## 결정

Windows 검증을 다음 네 계층으로 분리한다.

| 계층 | 목적 | 실행 대상 | 현재 상태 |
|---|---|---|---|
| 개발자 회귀 suite | PowerShell `5.1`의 세부 contract/files/runtime/lifecycle 회귀 검증 | 격리된 synthetic fixture | 호환 수정 구현, 현재 source의 새 Windows 결과 필요 |
| 운영자 smoke gate | 실제 점검 전에 핵심 lifecycle과 fail-closed 동작만 빠르게 확인 | 격리된 synthetic fixture | exact ten-test runner 구현, 새 Windows 결과 필요 |
| 실제 maintenance preflight | production 종료와 실제 process/listener 부재 확인 | 승인된 Windows 서버 | 앞의 두 gate 통과 전 차단 |
| Gate A 이후 기능 수용 | 실제 PalServer가 whole-`Saved` clone에서 의도한 상자만 안전하게 확장하는지 확인 | 폐기 가능한 전체 `Saved` 복제본 | mutation 구현 전 차단 |

기존 `tests/windows/Run-CgceDiscoveryTests.ps1`는 개발자/CI용 전체 회귀
suite로 유지한다. 테스트를 삭제하거나 성공 조건을 완화하지 않으며, 실제
maintenance 승인 전 Windows PowerShell `5.1`에서
`CGCE_WINDOWS_TESTS failures=0`이어야 한다.

운영자용 smoke runner는 별도 entry point
`tests/windows/Run-CgceDiscoverySmokeTests.ps1`로 구현됐고 handoff exact
allowlist에 포함된다. 마지막 줄이
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`일 때만 성공이다. Smoke 성공은
전체 회귀 suite를 대체하지 않고, 운영자가 전달받은 exact handoff에서 핵심
동작을 다시 확인하는 gate다.

## 운영자 smoke 범위

smoke runner는 다음 대표 동작만 검증한다.

1. Windows PowerShell `5.1` 및 대상 CLR 호환성
2. handoff ZIP, sidecar와 source manifest 검증
3. atomic state replacement와 compare-and-swap
4. Windows canonical path, path escape와 reparse point 거부
5. synthetic whole-`Saved` backup/clone inventory 일치
6. fake process identity와 listener 추적
7. UE4SS before-image staging과 exact restore
8. 대표 interruption 한 건의 deterministic resume
9. private export allowlist와 save/config/credential 제외
10. `prepare -> fake invoke -> restore -> export` 전체 lifecycle

세부 오류 조합과 edge case는 전체 회귀 suite에 남긴다. smoke fixture는 실제
production `Saved`, UE4SS 설치, PalServer process 또는 실제 `8211` listener를
읽거나 변경하지 않는다.

## 포트와 process 정책

- synthetic 회귀와 operator smoke는 mock telemetry 또는 실행 시 할당한 임시
  port를 사용한다.
- unrelated production server가 실제 `8211`을 사용 중이어도 synthetic
  smoke의 실패 원인이 되어서는 안 된다.
- synthetic test를 통과시키기 위해 production server, firewall, service,
  scheduler 또는 watchdog을 변경하지 않는다.
- 실제 maintenance에서는 production 자동 재시작 중지, 외부 ingress 차단,
  player disconnect와 정상 종료 후 control evidence에 기록한 실제
  TCP/UDP port의 listener가 모두 사라졌는지 확인한다.
- 실제 configured port에 listener가 남아 있거나 process identity가
  불명확하면 `[STOP]`이다. 이 검사는 제외하거나 mock으로 대체하지 않는다.

## Gate A 이후 whole-`Saved` clone 기능 수용

실제 Palworld save 형식을 별도 도구가 재현하거나 `.sav`를 직접 편집하지
않는다. 운영 서버를 정상 종료한 뒤 `Pal\Saved` 전체를 복제하고, 실제
PalServer가 그 복제본만 활성 `Saved`로 사용하도록 격리한다.

Exact symbol Gate A와 별도 mutation 구현·승인이 완료된 뒤 최소 기능 수용
조건은 다음과 같다.

1. 이미 초기화된 모든 대상 길드 상자의 슬롯 수가 승인된 목표값으로 증가한다.
2. 새 길드의 상자 Container ID가 초기화된 뒤 같은 migration을 적용하면
   목표 슬롯 수가 된다.
3. 기존 슬롯의 index, item static ID, dynamic GUID, quantity,
   durability/quality/instance metadata, container ID와 owner guild ID가
   before snapshot과 동일하고 새 슬롯은 비어 있다.
4. 일반 상자를 포함한 길드 외 컨테이너는 변경되지 않는다.
5. 정상 저장·종료·재시작 후 슬롯 수와 모든 데이터 불변조건이 유지된다.

여기서 “신규 상자 preset”은 모든 컨테이너의 전역 기본값이나 Palworld data
asset을 수정한다는 뜻이 아니다. 현재 제품 설계는 신규 길드 상자가 초기화된
후 기존 migration 함수를 적용한다. exact hook, resize API, empty-slot factory,
dirty/save/replication 의미는 실제 read-only Discovery 결과로 Gate A에서
승인되어야 한다.

이 최소 기능 수용만으로 정식 release가 완료되지는 않는다. 첫 release에
요구되는 Steam Windows, PS5, macOS client 인증과 더 넓은 복구·동시성
회귀는 별도 certification gate로 유지한다.

## 비목표

- 현재 Task 11A에 UObject write, resize, append 또는 save mutation 추가
- 실제 Palworld save byte를 직접 생성하거나 편집
- Windows 전체 회귀 test 삭제 또는 failure 허용
- 실제 maintenance의 process/listener 검증 완화
- Gate A approval, revision binding 또는 client platform 요구사항 우회

## 완료 기준

- 전체 개발자 회귀 suite가 elevated Windows PowerShell `5.1`에서
  `failures=0`이다.
- 별도 operator smoke runner가 구현되고 같은 환경에서 `failures=0`이다.
- production `8211`이 실행 중인 상태에서도 격리된 smoke가 production
  process, port와 filesystem에 접근하지 않고 통과한다.
- 승인된 실제 maintenance에서는 production 종료 후 configured process와
  listener가 남아 있으면 반드시 차단한다.
- Gate A 이후 기능 수용은 whole-`Saved` clone의 before/after inventory와
  게임 내 관찰로 위 다섯 조건을 입증한다.
