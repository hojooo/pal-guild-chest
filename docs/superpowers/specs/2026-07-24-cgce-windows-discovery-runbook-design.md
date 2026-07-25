# CGCE Windows Discovery 단계형 Runbook 설계

- 상태: 승인됨
- 작성일: 2026-07-24
- 대상 단계: Task 11A
- 상위 설계:
  `docs/superpowers/specs/2026-07-23-cgce-windows-discovery-operator-stage-design.md`
- 구현 계획:
  `docs/superpowers/plans/2026-07-23-cgce-windows-discovery-operator.md`
- 후속 검증 범위 결정:
  `docs/superpowers/specs/2026-07-26-cgce-windows-validation-scope-design.md`

> 2026-07-26 보완: 전체 PowerShell suite는 개발자/CI 회귀 gate로
> 유지하고, 운영자에게는 별도의 핵심 smoke gate를 제공한다. synthetic
> 검증은 실제 production `8211`과 격리하지만, 승인된 maintenance에서는
> production 종료 후 configured listener 부재 검사를 그대로 유지한다.

## 배경

개발 환경은 macOS이고 Palworld Dedicated Server와 UE4SS `3.0.1`은 별도
Windows 호스트에 있다. 해당 호스트는 테스트용 포트를 따로 사용할 수 없지만
운영 자동 재시작을 중지하고 외부 접속을 차단할 수 있다.

작성 당시 Task 11A.1–11A.6의 prepare, invoke, restore 구현은 존재했지만
Windows PowerShell `5.1` 동작 검증은 남아 있었다. 이후 Task 7 private
evidence export, Task 8 결정론적 handoff, Task 9 전체 합성 lifecycle source가
구현되었다. 2026-07-26 후속 Windows 검증 결과와 변경된 gate는 위 후속 설계를
따른다.

## 결정

`docs/windows-discovery-operator-runbook.md`를 Task 11A 전용 운영 문서로
추가한다. 기존 `docs/discovery-runbook.md`는 Task 11B/Gate A의 exact-symbol
discovery 문서로 유지한다.

새 Runbook은 모든 절차에 다음 상태 표기를 사용한다.

- `[READY NOW]`: 현재 구현과 검증 상태에서 바로 실행할 수 있다.
- `[IMPLEMENTATION BLOCKED]`: 필요한 도구나 검증 gate가 아직 없다.
- `[APPROVAL REQUIRED]`: 기술 gate는 충족했지만 실제 서버 변경을 위한 별도
  점검 승인이 필요하다.
- `[STOP]`: 더 진행하지 않고 기존 artifact를 보존해야 한다.

당시 `[READY NOW]` 범위는 별도 Windows 작업 복사본에서 Task 1–6 합성
PowerShell suite를 실행하는 것이었다. 이후 실제 Windows 실행에서
`failures=74`가 확인되었다. 이후 전체 suite 호환 수정과 exact ten-test
operator smoke source가 구현되어 synthetic full/smoke와 handoff 검증은
`[READY NOW]`다. 다만 현재 source의 새 Windows `failures=0` 증거는 아직
없으므로 실제 maintenance gate는 `[IMPLEMENTATION BLOCKED]`다.

Task 7–9와 Windows full regression 및 별도 operator smoke의 `failures=0`
gate가 모두 통과한 뒤에만 실제 server command를
`[APPROVAL REQUIRED]` 절차로 승격한다. 그 전에는 실제 server root,
`Saved`, UE4SS를 받는 명령을 실행 가능한 block으로 제공하지 않는다.

## Export 경계

`Export-CgceDiscoveryEvidence.ps1`는 네트워크 전송 도구가 아니다. 복원이
검증된 run에서 허용된 private evidence만 no-overwrite ZIP으로 봉인하고
SHA-256 sidecar를 만드는 local PowerShell 도구다.

입력은 `RunRoot`, `RunId`, `OutputDirectory`, 선택적 `Resume`이며, exact
`RESTORED/ACTIVE` state와 completed-only marker를 요구한다. ZIP에는 다음만
포함한다.

- `control-evidence.json`
- export 직전의 immutable `RESTORED` `run-state.json`
- original, backup, clone, restored inventory JSON
- `capture/UE4SS_ObjectDump.txt`
- `capture/CXXHeaderDump/**`
- `export-manifest.json`

`Saved`, `.sav`, `.ini`, `mods.txt`, credential/key material과 unallowlisted
path는 거부한다. ZIP과 sidecar를 다시 읽어 manifest 및 archived state를
검증하고, 모든 archived payload path/length/checksum이 current RESTORED
control/state/inventory/capture authority와 일치한 뒤에만 local state를
`EXPORTED/SUCCEEDED`로 전이한다. 만료된 control evidence나
handoff/run/server root와 겹치는 output root는 거부한다.

Inventory path/hash와 runtime dump 이름은 pseudonymous identifier를 노출할 수
있으므로 export는 source control, release, 공개 issue에 올리지 않는 private
artifact다.

## 운영 순서

구현과 운영 순서는 다음으로 고정한다.

1. Task 7 exporter와 rejection/resume test
2. Task 8 tracked-clean deterministic handoff builder/verifier
3. Task 9 `prepare -> fake invoke -> restore -> export` 합성 lifecycle
4. elevated Windows PowerShell `5.1` full regression `failures=0`
5. 별도 operator smoke `failures=0`
6. 별도 승인된 실제 Windows maintenance run
7. 개발 호스트에서 private ZIP/sidecar 재검증
8. 결과 검토 후 Task 11B 설계

실제 maintenance에서는 operator가 자동 재시작 중지, 외부 접속 차단, player
disconnect와 정상 종료를 직접 수행한다. 도구는 firewall, service, scheduler,
watchdog을 변경하거나 운영 서버를 시작하지 않는다.

## 실패와 복구

Checksum drift, stale control evidence, unknown descendant executable, 남은
listener, ambiguous filesystem layout, restored inventory mismatch는 모두
`[STOP]`이다.

실패 시 backup, inactive original, active/test clone, quarantine, receipt를
삭제하거나 덮어쓰지 않는다. 원본과 UE4SS before-image 복원이 검증되기 전에는
자동 재시작이나 외부 접속을 다시 활성화하지 않는다.

## 완료 기준

- macOS Lua suite와 discovery package verification이 통과한다.
- tracked-clean handoff source verifier가 통과한다.
- 같은 clean source에서 만든 두 handoff ZIP과 sidecar가 byte-identical이다.
- Windows PowerShell `5.1` full regression과 별도 operator smoke가 각각
  `failures=0`을 출력한다.
- 합성 lifecycle에서 original inventory가 복원되고 backup/quarantine이
  보존된다.
- private export의 manifest와 sidecar가 검증되고 save/config/credential이
  없다.
- 실제 run 전후 original/UE4SS inventory가 일치한다.

이 완료 기준은 Task 11A만 닫는다. Gate A acceptance, mutation authority,
Steam Windows/PS5/macOS certification 또는 release authority를 생성하지 않는다.
