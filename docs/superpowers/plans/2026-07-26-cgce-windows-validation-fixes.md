# CGCE Windows PowerShell 5.1 및 Operator Smoke 수정 계획

> 실행 원칙: 이 계획은 primary agent가 직접 순서대로 구현한다. 공통 상태·복구
> 계약이 강하게 연결되어 있으므로 서브에이전트로 작업을 분할하지 않는다.
>
> 구현 상태 (2026-07-26): PowerShell `5.1` 호환 수정, 동적 synthetic port,
> exact ten-test smoke runner와 handoff allowlist 반영은 완료됐다. macOS full
> Lua suite, discovery package verifier, handoff integration과 shell/static
> 검증은 통과했다. 현재 source의 Windows full/smoke pass transcript는 아직
> 없으므로 실제 maintenance는 계속 차단한다.

## 목표

Windows PowerShell `5.1` 전체 회귀 suite의 이전 source 결과
`174 total / 100 pass / 74 fail`을 공통 원인부터 수정해
`CGCE_WINDOWS_TESTS failures=0`으로 만든다. 그 뒤 운영자가 실제 서버
maintenance 전에 실행할 정확히 10개의 behavior-level smoke gate를 구현한다.

승인된 범위는
`docs/superpowers/specs/2026-07-26-cgce-windows-validation-scope-design.md`를
따른다.

## 접근 방식

1. Contract와 fixture의 PowerShell `5.1` 호환 결함을 먼저 수정한다.
2. Files, Runtime 순으로 직접 실패를 제거한다.
3. 공통 결함 때문에 발생한 Lifecycle cascade를 다시 측정한다.
4. 수정된 exact source에서는 Windows full regression을 먼저 실행하고,
   이어서 exact ten-test smoke를 실행해 두 transcript를 분리 보존한다.
5. Smoke는 기존 검증된 test 본문을 exact-name allowlist로 재사용하고,
   환경·포트 격리에 필요한 한 개의 전용 test만 추가한다.
6. Full regression과 smoke가 모두 통과하기 전에는 Runbook에 실제 server
   명령을 추가하지 않는다.

Production `Assert-CgceNoServerActivity`의 실제 process/listener 차단 동작은
완화하지 않는다. Synthetic fixture만 mock telemetry 또는 실행 시 할당한
임시 port를 사용한다.

## 현재 직접 원인

| 원인 | 대표 실패 | 처리 |
|---|---|---|
| PowerShell `5.1`의 `File.Replace` overload binding | state CAS와 prepare 이후 cascade | exact four-argument .NET overload를 private wrapper로 호출 |
| PSObject의 대소문자 비구분 속성 | `key`/`KEY` JSON 허용 | case-insensitive duplicate key 거부 |
| `FileInfo.Parent` 사용 | handoff manifest 검증 | `FileInfo.Directory`에서 부모 순회 시작 |
| 자동 변수 `$PID`와 변수·매개변수 충돌 | PID journal | 모든 `$pid` 지역 이름을 명시적 process 이름으로 변경 |
| .NET Framework UNC root 형태 차이 | canonical UNC root | trailing separator 유무를 모두 canonical root로 정규화 |
| stale export contract expectation | Files export test | 승인된 두 export를 expected set에 추가 |
| restore receipt가 있는데 intent 없이 재판정 가능 | recovery matrix | non-empty receipt root는 explicit intent 없으면 차단 |
| 고정된 2026-07-24 fixture 시간 | recovery state time ordering | genesis timestamp에서 단조 증가하는 fixture 시간 생성 |
| Runtime restore fixture의 state/marker authority 누락 | probe restore `missing file` | valid restore fixture에 genesis/state/marker를 명시적으로 생성 |
| Process.StartTime과 WMI DMTF 정밀도 차이 | root identity verification drift | 양쪽을 DMTF microsecond 정밀도로 canonicalize |
| synthetic test가 실제 `8211` telemetry를 읽음 | `CGCE-OPS-PORT-ACTIVE` | mock empty telemetry 또는 동적 임시 port 사용 |

74개 중 `CGCE-TEST synthetic prepare failed` 30건은 독립 결함으로 취급하지
않는다. 아래 공통 수정 후 새 Windows transcript에서 다시 판정한다.

## 변경되는 인터페이스

- 기존 full runner:
  `tests/windows/Run-CgceDiscoveryTests.ps1`
  - 기본 실행 방식과 마지막 줄
    `CGCE_WINDOWS_TESTS failures=<N>`을 유지한다.
- 신규 operator runner:
  `tests/windows/Run-CgceDiscoverySmokeTests.ps1`
  - Windows PowerShell `5.1` Desktop edition만 허용한다.
  - exact-name으로 선택된 10개 test가 모두 한 번씩 실행되어야 한다.
  - 마지막 줄은
    `CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=<N>`이다.
  - 하나라도 누락·중복·실패하면 exit code `1`이다.
- `TestHarness.ps1`:
  - full suite에서는 기존처럼 모든 test를 실행한다.
  - smoke runner가 설정한 exact-name allowlist가 있을 때만 나머지를
    side effect 없이 skip하고, 요청한 이름의 누락·중복을 실패로 기록한다.

## 안전 경계

- 실제 Palworld `Saved`, UE4SS 설치, PalServer executable을 test fixture로
  전달하지 않는다.
- 실제 UDP `8211`이 열려 있어도 synthetic test는 이를 configured test
  listener로 취급하지 않는다.
- 실제 maintenance에서는 production 종료 후 configured listener가 남아
  있으면 계속 `[STOP]`이다.
- 실패를 없애기 위해 expected error code, checksum binding, no-overwrite,
  recovery barrier 또는 inventory 비교를 완화하지 않는다.
- 이 계획에는 actual maintenance, Gate A observation, UObject mutation,
  길드 상자 확장 또는 client certification이 포함되지 않는다.

---

## Task 1. Contract JSON, state CAS, handoff traversal 수정

**목적:** 가장 큰 cascade 원인인 state replacement와 독립 Contract 호환
결함을 먼저 제거한다.

**파일:**

- Modify:
  `tools/windows-discovery/modules/CgceDiscovery.Contract.psm1`
- Modify: `tests/windows/Contract.Tests.ps1`

**RED:**

기존 Windows 실패를 그대로 사용한다.

- `strict JSON rejects duplicate and unrepresentable case-variant keys`
- `new run state has every exact field and state replacement increments once`
- `run-state replacement reopens new state while preserving the old file handle`
- `run-state replacement surfaces an injected reopen failure without deleting state`
- `handoff manifest accepts only the exact sorted payload allowlist`
- `blocked transition cannot introduce a compatible null checksum`

`blocked transition...` fixture는 active marker를 mutated `RUNNING` state가
아니라 byte-identical `CREATED` genesis에서 생성하도록 먼저 바로잡는다.

**최소 구현:**

1. JSON object key set을 `StringComparer.OrdinalIgnoreCase`로 만들고
   `key`/`KEY` 충돌을 stable `CGCE-OPS-JSON`으로 거부한다.
2. Private `Invoke-CgceFileReplaceNoBackup` helper를 추가한다.
   - `[string], [string], [string], [bool]` signature의 exact
     `System.IO.File.Replace` method를 reflection으로 한 번 resolve한다.
   - 네 원소 `object[]`의 세 번째 값을 실제 `$null`로 유지해 PowerShell
     overload binder의 empty-string 변환을 우회한다.
   - source temp와 destination은 기존과 같은 directory에 둔다.
   - replacement 실패 시 destination을 삭제하거나 fallback move하지 않는다.
3. `Replace-CgceRunStateJson`은 기존 두 checksum 비교, temp no-overwrite,
   open-handle semantics와 read-back 검증을 그대로 유지하고 private helper만
   호출한다.
4. Handoff leaf 자체를 검사한 뒤 directory 순회는 `$item.Directory`에서
   시작하고 `DirectoryInfo.Parent`로 root까지 올라간다.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
    '& { . .\tests\windows\TestHarness.ps1; . .\tests\windows\Contract.Tests.ps1; Write-Output ("CGCE_WINDOWS_TESTS failures=" + $script:CgceFailures); if ($script:CgceFailures -ne 0) { exit 1 } }'
```

**완료 조건:** 위 test들과 state CAS를 경유하는 recovery Contract test가
`failures=0`이며 `.tmp`가 성공 후 남지 않는다.

## Task 2. Contract recovery fixture의 단조 시간 보장

**목적:** 실행 날짜가 바뀌면 실패하는 고정 timestamp를 제거하되 production
시간 검증은 변경하지 않는다.

**파일:**

- Modify: `tests/windows/Contract.Tests.ps1`

**RED:**

- `recovery state writers reject state-only and sentinel-only manual barriers`
- `recovery blocker owns exact ACTIVE and BLOCKED revision-plus-two deltas`
- `recovery completion requires exact 000 010 020 999 authority`

**최소 구현:**

1. `New-CgceRecoveryContractFixture`가 생성한 state의
   `created_at_utc`/`updated_at_utc`를 fixture 기준 시각으로 사용한다.
2. intent, RESTORING state, operation receipts와 final receipt는 그 기준에서
   각각 1초씩 증가시킨 strict UTC 값을 사용한다.
3. BLOCKED error의 `at_utc`도 state 생성 시각보다 빠르지 않게 만든다.
4. Production의 `updated >= created`, source preimage와 receipt ordering
   validator는 수정하지 않는다.

**Windows 검증:** Task 1의 Contract 전용 명령을 다시 실행한다.

**완료 조건:** 현재 날짜와 무관하게 Contract file 전체가 `failures=0`이다.

## Task 3. Files UNC, export contract와 recovery intent 수정

**목적:** .NET Framework path 형태 차이와 intent 없는 recovery 재판정을
fail closed로 정리한다.

**파일:**

- Modify: `tools/windows-discovery/modules/CgceDiscovery.Files.psm1`
- Modify: `tests/windows/Files.Tests.ps1`

**RED:**

- `canonical paths preserve Windows volume roots and normalize descendants`
- `filesystem module exports only approved interfaces`
- `recovery matrix resumes only intent-bound before or after states`

**추가 RED assertion:**

- `\\server\share`와 `\\server\share\`가 모두
  `\\server\share\`로 canonicalize된다.
- UNC descendant의 trailing separator가 제거된다.
- `restore_receipts`에 `000-restore-intent.json` 또는 후속 receipt가 있는데
  `-Intent`를 생략하면 filesystem layout이 원본처럼 보여도
  `CGCE-OPS-MANUAL-RECOVERY`다.

**최소 구현:**

1. `GetPathRoot()`가 UNC root 끝의 separator를 생략해도 이를 유효한 volume
   root로 받아들인 뒤 정확히 한 개의 `\`를 붙인다.
2. Files export expected set에 이미 승인·구현된
   `Initialize-CgceRunLayout`,
   `Assert-CgceDiscoveryDiskCapacity`를 추가한다. Production export surface는
   바꾸지 않는다.
3. `Assert-CgceRecoveryMatrix`에서 `$Intent -eq $null`일 때
   `restore_receipts`가 존재하고 비어 있지 않으면 새 recovery case를
   추론하지 않고 차단한다.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
    '& { . .\tests\windows\TestHarness.ps1; . .\tests\windows\Files.Tests.ps1; Write-Output ("CGCE_WINDOWS_TESTS failures=" + $script:CgceFailures); if ($script:CgceFailures -ne 0) { exit 1 } }'
```

**완료 조건:** Files file 전체가 `failures=0`이고 intent-bound resume 외에는
receipt가 있는 layout을 자동 복구하지 않는다.

## Task 4. Runtime PID 이름과 creation-time identity 수정

**목적:** PowerShell 자동 변수 충돌과 Process/WMI 시간 정밀도 차이를
해결하면서 PID 재사용 검증을 유지한다.

**파일:**

- Modify:
  `tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1`
- Modify: `tests/windows/Runtime.Tests.ps1`

**RED:**

- `completed process result binds the exact immutable PID journal`
- `zero arguments omit ArgumentList and oversized commands never launch`
- `final sweep descendants re-enter bounded monitoring until terminated`
- `stale pre-parent ParentPID records never create receipts`
- `process crash seams preserve exact immutable partial receipts`
- 실제 child-process test의
  `CGCE-OPS-MANUAL-RECOVERY root identity verification drift`

**추가 RED assertion:**

- Runtime source와 test fixture에 local/parameter `$pid` 선언이 없다.
- 동일 creation instant를 나타내는 Process `FILETIME`과 WMI DMTF
  `CreationDate`가 microsecond canonicalization 후 같은 identity다.
- canonicalization 후 1 microsecond 이상 다른 creation time은 계속
  identity drift다.

**최소 구현:**

1. `Write-CgceProcessPidReceipt`의 `$Pid`를 `$ProcessId`로 바꾸고 JSON field
   이름 `pid`는 유지한다.
2. `Assert-CgceNoServerActivity`의 local `$pid`를
   `$observedProcessId`, test fixture `$pid`를 `$pidReceipt`로 바꾼다.
3. Private creation-time canonicalizer를 추가한다.
   - positive `FILETIME`을 DMTF의 microsecond 정밀도에 맞게 nearest
     microsecond로 round한다.
   - immediate `Process.StartTime`과 WMI `CreationDate` 양쪽에 동일하게
     적용한다.
   - PID, canonical executable path와 canonicalized creation time 세 값의
     exact equality는 유지한다.
4. Receipt에는 canonicalized `creation_time_filetime_utc`와 그로부터 만든
   UTC string만 기록한다.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
    '& { . .\tests\windows\TestHarness.ps1; . .\tests\windows\Runtime.Tests.ps1; Write-Output ("CGCE_WINDOWS_TESTS failures=" + $script:CgceFailures); if ($script:CgceFailures -ne 0) { exit 1 } }'
```

**완료 조건:** 실제 `cmd.exe` fixture를 포함한 process receipt test가
`failures=0`이며 PID/path/time drift rejection은 그대로 통과한다.

## Task 5. Runtime restore authority와 synthetic telemetry 격리

**목적:** valid restore test가 production과 같은 state/marker authority를
갖도록 하고 실제 host의 `8211` 상태에서 분리한다.

**파일:**

- Modify: `tests/windows/Runtime.Tests.ps1`

**RED:**

- `inventory probe writes one exact mods line and sole final receipt`
- `probe staging crash points restore exact UE4SS before images`
- `probe restore resumes every operation and receipt crash boundary`
- `completed restore revalidates final bindings and live terminal matrix`
- `probe restored validator is read-only over absent and completed authorities`
- `probe restore manual barriers prevent the next move or receipt`

**최소 구현:**

1. Valid recovery fixture용
   `Initialize-CgceRuntimeRestorableProbeFixture` helper를 둔다.
   - stage receipt를 만든다.
   - original/backup/clone inventory authority를 기록한다.
   - byte-identical genesis/state와 active marker를 만든다.
   - state를 exact `PROBE_STAGED` checkpoint로 전환한다.
2. Valid restore를 기대하는 test만 이 helper를 사용한다. Missing-intent,
   residue, corrupted-authority test에는 authority를 자동 보충하지 않는다.
3. `New-CgceRuntimeProbeFixture`가 임시 port를 할당해 fixture에 보존하고
   recovery state의 `listener_ports`는 그 값을 사용한다.
4. “activity 없음”을 전제로 하는 unit test는
   `New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()` seam을
   명시하고 `finally`에서 항상 해제한다.
5. Process/TCP/UDP active 경계를 검증하는 test는 기존 injected snapshot을
   유지한다. Production activity 함수는 수정하지 않는다.
6. Mock snapshot에 unrelated UDP `8211`이 있어도 configured fixture port가
   다르면 통과하고, configured port가 같으면
   `CGCE-OPS-PORT-ACTIVE`인지 추가 검증한다.

**Windows 검증:** Task 4의 Runtime 전용 명령을 다시 실행한다.

**완료 조건:** Runtime file 전체가 실제 production `8211`의 활성 여부와
무관하게 `failures=0`이고 injected configured listener 차단 test는 통과한다.

## Task 6. Lifecycle fixture의 동적 port와 cascade 재검증

**목적:** full entry-point test를 실제 host 환경에서 분리하고 공통 수정으로
prepare/invoke/restore/export cascade가 사라졌는지 확인한다.

**파일:**

- Modify: `tests/windows/Lifecycle.Tests.ps1`

**RED:**

- `prepare preserves original and activates an equal clone with one terminal line`
- `prepare replay rejects the existing final run directory without another mutation`
- `invoke runs a relocated prepared child once and captures only exact dump outputs`
- `restore returns the exact original and quarantines the clone`
- `export archives the exact private allowlist after restore`
- `full synthetic lifecycle restores original bytes and exports evidence`

**최소 구현:**

1. `New-CgceLifecycleUnusedPort`가 loopback TCP와 UDP 양쪽에서 사용할 수 있는
   port를 OS에 요청하고 reservation을 해제한 뒤 fixture에 기록한다.
2. `New-CgceSyntheticFixture`의 고정 `65534`를 그 port로 교체한다.
3. Detached-listener case도 같은 allocator를 사용하되 base port와 다른 값을
   요구한다.
4. Control evidence, fake server argument와 assertion은 fixture port만
   사용한다. `8211`을 synthetic control에 추가하지 않는다.
5. Expected error code를 `CGCE-OPS-BLOCKED`로 낮추거나 lifecycle assertion을
   삭제하지 않는다. State CAS가 정상화되면 원래 stable code가 그대로
   복원되어야 한다.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
    '& { . .\tests\windows\TestHarness.ps1; . .\tests\windows\Lifecycle.Tests.ps1; Write-Output ("CGCE_WINDOWS_TESTS failures=" + $script:CgceFailures); if ($script:CgceFailures -ne 0) { exit 1 } }'
```

**완료 조건:** Lifecycle file 전체가 `failures=0`; original bytes, backup,
quarantined clone, marker와 export allowlist assertion이 모두 유지된다.

## Task 7. 전체 회귀 재기준 gate

**목적:** smoke 구현 전에 기존 회귀 suite가 완전히 복구됐음을 증명한다.

**파일 변경:** 없음.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

**완료 조건:**

- 마지막 줄이 정확히 `CGCE_WINDOWS_TESTS failures=0`
- exit code `0`
- `FAIL` line 없음
- 실제 server root, `Saved`, UE4SS path를 입력하지 않음

잔여 failure가 있으면 smoke 구현으로 넘어가지 않는다. Expected error를
완화하지 않고 새 transcript에서 최초의 비-cascade failure를 재현하는 최소
test를 추가한 뒤 이 계획을 보완한다.

## Task 8. Exact 10-test operator smoke runner 구현

**목적:** 전체 회귀를 대체하지 않는 작고 결정론적인 운영자 gate를 만든다.

**파일:**

- Modify: `tests/windows/TestHarness.ps1`
- Add: `tests/windows/Smoke.Tests.ps1`
- Add: `tests/windows/Run-CgceDiscoverySmokeTests.ps1`
- Modify: `tests/windows/Run-CgceDiscoveryTests.ps1`

**RED:**

1. Smoke runner 파일이 없으면 handoff/static test가 실패한다.
2. `Smoke.Tests.ps1`에
   `test harness rejects duplicate and missing smoke selections`를 추가한다.
   이 test는 fresh child `powershell.exe`에서 harness만 로드하고 duplicate
   selection과 실행되지 않은 selection을 각각 stable selection failure로
   확인한다. Operator의 10-test selection에는 포함하지 않는다.
3. PowerShell `7`/Core 또는 Windows PowerShell `5.1`이 아닌 환경에서
   environment smoke가 실패해야 한다.

**정확한 smoke selection:**

1. `Windows PowerShell 5.1 smoke isolates unrelated production activity`
2. `handoff manifest accepts only the exact sorted payload allowlist`
3. `run-state replacement reopens new state while preserving the old file handle`
4. `canonical paths preserve Windows volume roots and normalize descendants`
5. `path component scan rejects a junction before the target`
6. `verified tree copy returns an exact inventory and never overwrites`
7. `recovery matrix resumes only intent-bound before or after states`
8. `probe restored validator is read-only over absent and completed authorities`
9. `export archives the exact private allowlist after restore`
10. `full synthetic lifecycle restores original bytes and exports evidence`

**최소 구현:**

1. Harness에 exact ordinal selection, requested/executed set와 duplicate/missing
   검증을 추가한다. Selection이 없으면 기존 full behavior는 byte-for-byte
   동일한 출력 계약을 유지한다.
2. Harness contract test는 별도 child process에서 selection state를
   격리하며 full regression에서 실행된다. Smoke run에서는 skip되어 정확히
   10개만 실행된다.
3. `Smoke.Tests.ps1`의 environment/activity test는 다음을 한 번에 검증한다.
   - `PSEdition=Desktop`
   - version exact `5.1`
   - CLR major `4`
   - mock snapshot의 unrelated UDP `8211`은 다른 configured port 검사에
     영향을 주지 않음
   - allowlisted fake process identity는 계속 active로 차단됨
4. Smoke runner는 harness, Smoke/Contract/Files/Runtime/Lifecycle test file을
   dot-source하되 위 10개 이름만 실행한다.
5. Requested test가 모두 정확히 한 번 실행된 뒤에만
   `CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`을 출력한다.
6. Full runner에도 `Smoke.Tests.ps1`를 포함해 harness contract와
   environment/isolation test가
   전체 회귀에서도 실행되게 한다.

**Windows 검증:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

**완료 조건:** Smoke는 정확히 10 PASS와
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`, full regression은
`CGCE_WINDOWS_TESTS failures=0`이다.

## Task 9. Handoff allowlist와 deterministic bundle 정렬

**목적:** 새 smoke source가 checksum-bound handoff에만 포함되고 다른 파일은
계속 거부되게 한다.

**파일:**

- Modify: `scripts/verify-discovery-handoff.sh`
- Modify: `scripts/build-discovery-handoff.sh`
- Modify:
  `tools/windows-discovery/modules/CgceDiscovery.Contract.psm1`
- Modify: `tests/windows/Contract.Tests.ps1`
- Modify: `tests/windows/Lifecycle.Tests.ps1`
- Modify: `tests/integration/discovery_handoff_spec.lua`

**RED:**

`tests/integration/discovery_handoff_spec.lua`의 expected payload에 다음을 먼저
추가한다.

- `tests/windows/Smoke.Tests.ps1`
- `tests/windows/Run-CgceDiscoverySmokeTests.ps1`

Builder/verifier/Contract allowlist를 갱신하기 전 integration test가 실패하는지
확인한다.

**최소 구현:**

1. Shell verifier, shell builder, Contract `$script:CgceHandoffPaths`,
   Contract fixture와 Lifecycle fixture의 exact sorted set에 두 파일을
   추가한다.
2. Smoke runner가 handoff root 밖 module을 import하지 않는지 static
   assertion을 추가한다.
3. Existing DLL/save/config/private-evidence/symlink 거부와 deterministic
   timestamp/permission은 변경하지 않는다.

**macOS 검증:**

```sh
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
git diff --check
```

새 파일은 tracked source여야 하며 builder는 clean worktree만 허용한다. 따라서
아래 clean handoff gate는 변경이 검토·커밋된 뒤 실행한다.

```sh
./scripts/verify-discovery-handoff.sh
first_directory=$(mktemp -d)
second_directory=$(mktemp -d)
./scripts/build-discovery-handoff.sh \
  "$first_directory/CGCE-Windows-Discovery-Handoff.zip"
./scripts/build-discovery-handoff.sh \
  "$second_directory/CGCE-Windows-Discovery-Handoff.zip"
cmp \
  "$first_directory/CGCE-Windows-Discovery-Handoff.zip" \
  "$second_directory/CGCE-Windows-Discovery-Handoff.zip"
cmp \
  "$first_directory/CGCE-Windows-Discovery-Handoff.zip.sha256" \
  "$second_directory/CGCE-Windows-Discovery-Handoff.zip.sha256"
```

**완료 조건:** verifier 성공, 두 ZIP과 두 sidecar가 각각 byte-identical,
manifest에 두 smoke 파일이 exact checksum으로 포함된다.

## Task 10. Windows 최종 gate와 문서 승격

**목적:** 실제 서버 작업을 승인하기 전에 개발/운영 검증 증거를 모두
확정한다.

**파일:**

- Modify: `docs/windows-discovery-operator-runbook.md`
- Modify: `tools/windows-discovery/README.md`
- Modify: `CrossplayGuildChestExpander/README.md`
- Modify: `docs/requirements-traceability.md`
- Modify:
  `docs/superpowers/plans/2026-07-22-cgce-implementation.md`
- Modify:
  `docs/superpowers/plans/2026-07-23-cgce-windows-discovery-operator.md`

**Windows 검증:**

새 extraction directory의 verified handoff root에서 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1
```

**문서 변경 조건:**

- Full transcript 마지막 줄이 `CGCE_WINDOWS_TESTS failures=0`
- Smoke transcript 마지막 줄이
  `CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`
- 두 실행의 source commit, handoff ZIP SHA-256,
  `source-manifest.sha256` SHA-256을 private run record에 보존
- Smoke가 production `Saved`, UE4SS, PalServer path를 받지 않음
- 실제 `8211`이 열려 있어도 smoke가 unrelated listener로 무시함

Source 구현과 macOS 안전 검증이 끝나면 실제 server path를 받지 않는 smoke와
Windows handoff 검증은 `[READY NOW]`로 바꾸고 exact 실행 명령을 제공한다.
여기서 `[READY NOW]`는 합성 검증을 실행해도 안전하다는 뜻이지 gate 통과를
뜻하지 않는다. 위 Windows 조건을 모두 충족한 뒤에만:

1. 두 Windows gate를 현재 source의 통과 증거로 기록한다.
2. 실제 maintenance는 자동 승인하지 않는다. Mac/handoff gate와 사용자의
   별도 점검 승인이 모두 있을 때만 `[APPROVAL REQUIRED]`로 유지한다.
3. 현재 `100 pass / 74 fail` 문구를 새 증거로 교체하되 과거 결과는 후속
   설계의 baseline 기록으로 남긴다.

## 전체 완료 기준

- Contract, Files, Runtime, Lifecycle 각각 Windows PowerShell `5.1`
  `failures=0`
- Full regression `CGCE_WINDOWS_TESTS failures=0`
- Operator smoke exact 10 tests,
  `CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`
- Smoke는 unrelated production `8211`과 실제 filesystem/process에서 격리
- Actual maintenance의 configured listener fail-closed behavior 유지
- macOS full Lua suite 및 discovery package verifier 통과
- tracked-clean deterministic handoff 두 빌드 byte-identical
- save/config/credential/private evidence가 handoff에 없음
- production Lua는 mutation incapable 상태 유지
- 실제 Palworld server maintenance는 아직 실행하지 않음
