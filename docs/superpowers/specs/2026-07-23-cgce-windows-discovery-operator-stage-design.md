# CGCE Windows Discovery Operator Stage 설계

- 상태: Task 11A.5 휴대형 구현·정적 검토 완료, Windows PowerShell 5.1
  gate 미실행, Task 11A.6 복구 계약 확정
- 작성일: 2026-07-23
- 갱신일: 2026-07-24
- 단계: Task 11A
- 상위 설계:
  `docs/superpowers/specs/2026-07-23-cgce-remote-discovery-handoff-design.md`

## 배경

개발과 패키징은 macOS에서 수행하지만 실제 Palworld Dedicated Server와
UE4SS `3.0.1`은 별도의 Windows 서버에 있다. 테스트 서버는 운영 서버와 다른
포트를 사용할 수 없지만, 운영 자동 재시작을 멈추고 외부 접속을 차단할 수
있다.

현재 필요한 것은 Gate A 전체를 한 번에 구현하는 것이 아니다. 먼저 운영
원본을 보존한 채 같은 포트에서 복제 월드와 격리된 읽기 전용 inventory
probe를 한 번 실행하고, 결과를 보존한 뒤 운영 원본을 정확히 복원하는
operator 도구가 필요하다.

## 목표

1. macOS에서 결정론적인 Windows handoff ZIP과 SHA-256 sidecar를 만든다.
2. Windows PowerShell `5.1` 기본 기능과 .NET만으로 실행한다.
3. 운영 `Pal\Saved` 전체를 검증된 별도 backup에 복사한다.
4. 운영 `Saved`를 비활성 이름으로 보존하고, 검증된 clone만 활성 경로에 둔다.
5. UE4SS `3.0.1`의 격리 Lua inventory mod로 object dump와 C++ header dump를
   생성한다.
6. 서버 종료 후 test clone을 quarantine하고 운영 원본과 UE4SS mod 설정을
   복원한다.
7. save/config/credential을 제외한 private evidence ZIP과 checksum을 만든다.
8. 모든 실패에서 운영 서버를 자동 시작하거나 외부 접속 차단을 해제하지 않는다.

## 비목표

- Gate A `1.1` acceptance를 생성하지 않는다.
- production `main.lua` bootstrap 차단을 해제하지 않는다.
- runtime binding manifest, exact Palworld symbol 선택, candidate observation을
  구현하지 않는다.
- fatal-safety candidate를 호출하거나 검증하지 않는다.
- property write, `TArray` mutation, resize, append, dirty, replication,
  `ExecuteInGameThread`를 추가하지 않는다.
- Windows firewall, service, watchdog, scheduler를 도구가 변경하지 않는다.
- DLL, C++ mod, MSVC Build Tools, 별도 Windows build runner를 요구하지 않는다.
- Steam Windows, PS5, macOS client 호환 또는 release 가능성을 주장하지 않는다.

## 신뢰 경계

이 단계는 operator가 관리하는 단일 Windows host를 전제로 한다. local
administrator가 실행 중 파일을 악의적으로 교체하는 상황까지 방어하는 도구가
아니다. 대신 다음 operational invariant를 fail-closed로 검사한다.

1. 준비와 복원 시 operator가 exhaustive하다고 attest한 control-bound exact
   launcher/descendant executable path와 prior-run PID identity에 해당하는
   process가 없고 configured TCP/UDP listener가 없다. completeness를 attest할
   수 없거나 실행 중 unlisted descendant가 발견되면 차단한다.
2. operator가 자동 재시작 중지, 외부 접속 차단, 사용자 disconnect,
   UE4SS version/checksum을 `control-evidence.json`에 명시했다.
3. control evidence의 실제 file SHA-256이 CLI로 전달된 checksum과 같다.
4. `ServerRoot`와 `RunRoot`는 서로 같거나 중첩되지 않는다. active Saved,
   inactive original, test quarantine은 같은 server volume의 서로 다른
   sibling이고, backup/capture는 RunRoot 아래에만 둔다. UE4SS before-image와
   generated-output quarantine도 UE4SS root와 같은 volume의 run-id sibling
   path를 쓴다. 의도된 부모-자식 관계를 제외한 모든 mutable tree는 canonical
   path가 서로 같거나 중첩되지 않으며, source와 destination tree에는 reparse
   point가 없다.
5. backup과 clone의 sorted relative-path/length/SHA-256 inventory가 원본과 같다.
6. 테스트 실행 중 inactive original은 PalServer가 사용하는 active path가 아니다.
7. 복원 전 PalServer와 listener가 다시 0개다.
8. 복원 후 active Saved inventory가 준비 전 original inventory와 같다.
9. 도구는 운영 서버 start, network unblock, service enable을 수행하지 않는다.
10. server root의 no-overwrite active-run marker는 한 RunId/RunRoot만 소유하며,
    immutable genesis-state checksum에 결합되고 restore 검증 후에만 completed
    marker로 이동한다. mutable current state checksum과 혼동하지 않는다.
    foreign active marker나 original before-image가 남아 있으면 새 run을
    거부한다.
11. Prepare가 검증한 `source-manifest.sha256`의 SHA-256은 committed genesis와
    current state의 필수 immutable `source_manifest_checksum`이다. fresh
    `New-CgceRunState` object에서만 잠시 `null`일 수 있고, genesis를 쓰기
    전에는 strict lowercase 64-hex 값이어야 한다. 이후 모든 state identity와
    compare-and-swap 검사는 이 값을 바꿀 수 없는 실행 authority로 취급한다.
12. Invoke는 CLI에 handoff 경로를 추가하지 않는다. 자신의 `$PSScriptRoot`에서
    handoff root와 manifest를 도출하고, built-in-only bootstrap으로
    `run-state.genesis.json`을 strict size/UTF-8 및 exact single
    case-sensitive `source_manifest_checksum` property로 읽는다. 현재 manifest
    checksum과 import 대상 module bytes를 확인하는 작업은
    before importing any handoff module 수행한다. 그 뒤에만 검증된 module을
    import하고 full state/marker와 전체 handoff payload를 다시 검증한다. 이
    순서는 re-signed tree가 module code를 먼저 실행하는 것을 막으며 실패
    테스트는 no module side effect를 증명한다.
13. Path identity는 source tree 위치가 아니라 manifest bytes에 결합한다.
    따라서 same verified bytes may be relocated. 단, handoff tree and RunRoot must not overlap;
    동일하거나 양방향으로 포함되는 경우 import 전에 차단한다.

검사 도중 path identity나 inventory가 바뀌거나 상태가 불명확하면 자동
덮어쓰기 대신 `BLOCKED`로 끝내고 original, backup, clone을 모두 보존한다.

## 산출물

### macOS source artifact

- `CGCE-Windows-Discovery-Handoff.zip`
- `CGCE-Windows-Discovery-Handoff.zip.sha256`
- ZIP 내부 `source-manifest.sha256`

Handoff ZIP은 다음 tracked source만 포함한다.

```text
tools/windows-discovery/
├── README.md
├── CgceDiscovery.Common.psm1
├── modules/
│   ├── CgceDiscovery.Contract.psm1
│   ├── CgceDiscovery.Files.psm1
│   └── CgceDiscovery.Runtime.psm1
├── Prepare-CgceDiscovery.ps1
├── Invoke-CgceDiscovery.ps1
├── Restore-CgceProduction.ps1
├── Export-CgceDiscoveryEvidence.ps1
├── schemas/
│   ├── control-evidence.schema.json
│   ├── run-state.schema.json
│   └── export-manifest.schema.json
└── probe/
    └── CGCEDiscoveryInventory/
        └── scripts/
            └── main.lua
tests/windows/
├── TestHarness.ps1
├── Contract.Tests.ps1
├── Files.Tests.ps1
├── Runtime.Tests.ps1
├── Lifecycle.Tests.ps1
├── Run-CgceDiscoveryTests.ps1
└── fixtures/
    └── FakePalServer.cmd
```

`*.dll`, saves, config, credentials, private evidence와 vendored Lua runtime은
handoff ZIP에 들어갈 수 없다.

### Windows private run artifact

```text
<RunRoot>/<run_id>/
├── control-evidence.json
├── run-state.genesis.json
├── run-state.json
├── before/
│   └── checksums and inventories for preserved UE4SS before-images
├── inventories/
│   ├── original.json
│   ├── backup.json
│   ├── clone.json
│   └── restored.json
├── backup/Saved/
├── capture/
│   ├── UE4SS_ObjectDump.txt
│   └── CXXHeaderDump/
└── receipts/
    ├── probe/
    │   └── intent plus one chained no-overwrite JSON receipt per operation
    ├── process/
    │   └── launch intent, PID observations, and final result
    └── restore/
        └── intent plus one chained no-overwrite JSON receipt per operation
```

`backup`, same-volume quarantine, 운영 원본은 operator가 복원 성공을
확인하기 전까지 삭제하지 않는다.

inactive original은
`<ServerRoot>\Pal\Saved.cgce-original-<run_id>`에 있으며 RunRoot artifact의
하위가 아니다. test Saved quarantine은
`<ServerRoot>\Pal\Saved.cgce-test-<run_id>`에 둔다. probe, modified
`mods.txt`, generated dump/log quarantine과 pre-existing UE4SS before-image도
각 original과 같은 volume의 run-id-qualified sibling path에 둔다.

### Windows export artifact

- `CGCE-Windows-Discovery-<run_id>.zip`
- `CGCE-Windows-Discovery-<run_id>.zip.sha256`

Export ZIP은 control evidence, export 직전의 `RESTORED` run-state snapshot,
four inventories, object dump, CXX header dump와 export manifest만 포함한다.
local run-state는 ZIP과 sidecar read-back이 성공한 뒤에만 `EXPORTED`가 된다.
`Pal\Saved`,
`PalWorldSettings.ini`, `PalModSettings.ini`, `mods.txt`, passwords,
administrator/RCON/REST credentials는 포함하지 않는다.
Inventory에는 save bytes가 없지만 relative path/hash가 pseudonymous
world/player identifier를 드러낼 수 있고 dump도 private runtime name을 담을 수
있다. 따라서 export는 공개 issue, source control, release artifact에 올리지
않는 private evidence다.

## 상태 모델

```text
CREATED
  -> BACKUP_VERIFIED
  -> ORIGINAL_DEACTIVATED
  -> CLONE_ACTIVE
  -> PROBE_STAGED
  -> RUNNING
  -> CAPTURED
  -> RESTORING
  -> RESTORED
  -> EXPORTED
```

상태는 `phase`와 `outcome=ACTIVE|SUCCEEDED|BLOCKED`를 분리한다. 오류가
발생하면 현재 phase를 보존하고 outcome만 `BLOCKED`로 바꾼다. `BLOCKED`에서도
process가 멈춘 뒤 explicit restore는 허용하지만 다음 run이나 production
start는 허용하지 않는다. `SUCCEEDED`는 restore 검증과 export가 모두 끝난
`EXPORTED`에서만 기록한다.

`run-state.genesis.json`은 `CREATED` 상태의 immutable snapshot이다. active
marker는 이 파일의 checksum과 RunId/RunRoot를 결합한다. 이후 mutable
`run-state.json`이 compare-and-swap으로 전이되어도 marker의 genesis binding은
바뀌지 않으며, 모든 entry point는 marker, genesis, current-state identity를
함께 검증한다. Genesis와 current state는 Prepare가 검증한
`source-manifest.sha256`의 lowercase SHA-256을
`source_manifest_checksum`으로 함께 보존한다. 필드 누락, `null`, 대문자,
line-ending suffix 또는 genesis/current/CAS drift는 모두
`CGCE-OPS-CHECKSUM`으로 차단한다.

Task 11A.3 runtime journal은 기존 exact 41-key `Paths` schema를 변경하지
않는다. `receipts\process\000-launch.json`은 `Start-Process` 전에 생성·검증되는
immutable launch intent이며 PID 정보로 교체하지 않는다. root/descendant
identity는 gapless `001..998-pid.json`, 성공 결과는 `999-result.json`에
checksum chain으로 기록한다. argument plaintext는 receipt에 기록하지 않고
framed digest와 count만 기록한다. Launch intent에는 exact
`control_valid_until_utc`도 기록하며 전체 timeout window가 그 deadline 안에
들어오지 않으면 process를 만들기 전에 차단한다. Probe는 fixed `before\`
metadata snapshots,
`receipts\probe\000/010..060/999`, 그리고 fixed `restore\000/010..090/999`
children만 사용하며 valid receipt-prefix와 intent-bound exact filesystem
matrix가 함께 증명될 때만 no-overwrite recovery를 계속한다. 이 derived-path
allowlist는 Task 3 Runtime-owned journal/snapshot에만 적용되며 Task 5/7의
fixed capture children은 각 task contract를 따른다.

Probe restore intent는 `PROBE`, `MODS_TXT`, `OBJECT_DUMP`,
`CXX_HEADER_DUMP`, `UE4SS_LOG`의 exact entry state와 selected case를 step
010 전에 고정한다. 이후 010..090은 각각 probe quarantine, test mods
quarantine/original restore, object quarantine/original restore, header
quarantine/original restore, log quarantine/original restore의 fixed
source/destination만 사용한다. 각 missing receipt에서 live state가 intent의
exact before state이면 operation을 한 번 수행하고, exact after state이면
crash-before-receipt로 인정해 operation 없이 receipt만 완성한다. 그 외
layout은 overwrite 없이 `CGCE-OPS-MANUAL-RECOVERY`다.

Process preflight는 attested exact executable image, valid durable
PID/path/creation-FileTime identity, configured TCP/UDP endpoint를 fail-closed로
차단한다. receipt-aware preflight는 현재 canonical executable allowlist의
framed count/digest가 launch intent와 exact match인지도 검증한다. Launch 후
known root ancestry polling으로 실제 관찰한 descendant만 allowlist enforcement
대상이다. Numeric `ParentProcessId`는 exactly one observed parent identity와
일치하고 descendant creation FileTime이 그 exact parent보다 빠르지 않을
때만 ancestry edge로 인정한다. Receipt reader도 같은 unique-parent/temporal
invariant를 강제하여 stale ParentProcessId가 재사용된 PID에 연결되는 것을
막는다. Polling interval 사이에 시작·종료한 극단적으로 짧은 descendant의
완전한 history나 kernel-enforced containment를 주장하지 않는다.
Polling은 monotonic timeout 안에서 최대 100 ms의 bounded wait slice만 사용하고
각 slice 사이 process snapshot을 갱신한 뒤 quiescence identity sweep을
수행한다. 해당 sweep에서 처음 발견한 live descendant는 남은
timeout/control/launch deadline 안의 동일 bounded loop로 다시 들어가며, 이후
sweep에서 live observed identity가 0이 되기 전에는 성공하지 않는다.
관찰한 unlisted descendant는 allowlist 실패를 던지기 전에 gapless PID
receipt로 보존되므로 incomplete journal에서도 restore liveness 검사에
포함된다. 반대로 completed result에는 allowlisted identity만 허용한다.
관찰한 descendant의 executable/creation identity를 읽을 수 없으면 normal PID
receipt를 추측하지 않고 exact no-overwrite
`manual-recovery-required.json` sentinel에 run/PID/parent/observed UTC와 이전
receipt checksum을 기록한다. 이 sentinel이 존재하는 journal은 process가
사라진 뒤에도 항상 `CGCE-OPS-MANUAL-RECOVERY`이며 자동 restore 대상이 아니다.
동일 numeric PID가 다른 identity로 재사용되거나 bounded `001..998` receipt
범위가 다음 identity를 보존할 수 없는 경우에도 먼저 같은 chained sentinel을
기록하고 수동복구로 종료하여 evidence-free ambiguity를 허용하지 않는다.
Launch receipt를 semantic read-back한 뒤 Runtime은 mandatory
`PreLaunchValidation` callback을 `Start-Process` 직전에 output-suppressed로
실행한다. Invoke가 제공하는 callback은 held lock 아래 fresh `RUNNING`
state/marker, full probe journal/live matrix, control, process inactivity,
inventories, PalServer/UE4SS bytes와 전체 handoff source authority를 다시
검증한다. Runtime은 callback에 semantic read-back이 끝난 launch receipt
checksum을 전달하고 staged validator는 그 파일만 process journal에 존재하는
exact pre-launch shape를 요구한다.

## 실행 흐름

### 1. Build

macOS builder는 clean tracked commit에서만 동작한다. 기존
`scripts/verify-package.sh discovery`를 먼저 통과하고, current-stage allowlist를
staging한 뒤 fixed timestamp와 sorted entry order로 ZIP을 만든다.

### 2. Prepare

`Prepare-CgceDiscovery.ps1`은 다음을 수행한다.

1. handoff, control evidence, exhaustive server process-path attestation, UE4SS
   version, required cmdlet와 disk space를 검증한다.
   검증된 manifest checksum은 lock 전 capture하고, lock 획득 후 genesis
   생성 전에 동일 manifest와 전체 payload를 다시 검증한다.
2. PalServer process/listener가 0개인지 확인한다.
3. Saved tree의 reparse point를 거부한다.
4. original inventory와 immutable genesis state/current state/active marker를
   만든 뒤 run root의 backup에 복사한다.
5. backup inventory가 original과 같은지 확인한다.
6. active `Saved`를 `Saved.cgce-original-<run_id>`로 rename한다.
7. backup에서 새 active clone을 만들고 inventory를 다시 검증한다.
8. 기존 `Mods\mods.txt`를 same-volume no-overwrite before-image로 이동하고
   verified copy에 probe line을 추가한다. 기존 dump output과 `UE4SS.log`도
   same-volume before-image sibling으로 이동해 probe output path를 비운다.
9. preserved original과 별도로 fresh `mods.txt`를 만들고
   `CGCEDiscoveryInventory : 1`만 유일한 non-comment line으로 기록한 뒤
   `CGCEDiscoveryInventory\scripts\main.lua`를 staging한다.

기존 probe directory가 있거나 exact mods line이 중복되면 overwrite하지 않고
차단한다.

### 3. Invoke

`Invoke-CgceDiscovery.ps1`은 exact PalServer executable과 JSON argument array만
받는다. `-publiclobby`와 secret-bearing argument를 거부하고 child PID를 기록한
뒤 한 번 실행하고 종료를 기다린다.
Argument/path array는 각각 최대 4096개이고 개별 token/path도 4096자를 넘을 수
없다. Timeout은 1..86400초이며 현재 control evidence의 remaining validity
안에 전체 window가 들어와야 한다.
Public argument token은 비어 있지 않은
`^[-A-Za-z0-9_=.:/\\]+$`만 허용한다. 공백, quote, control character, shell
metacharacter와 response-file syntax는 fail-closed로 거부한다. Runtime은
허용된 token도 표준 Windows command-line quoting으로 하나의 명시적 native
argument line에 직렬화하며, private encoder는 차단된 edge vector까지 별도 argv
round-trip test로 검증한다. zero-token array는 `ArgumentList`를 생략하고,
quoted executable을 포함한 전체 native command line이 32,766자를 넘으면 launch
intent 생성 전에 차단한다.

Invoke의 CLI는 `RunRoot`, `RunId`, exact PalServer executable, argument JSON,
timeout만 받는다. entry point는 자신의
`<handoff>\tools\windows-discovery` 위치에서 handoff root와
`source-manifest.sha256`을 도출한다. 어떠한 handoff module도 import하기 전에
built-in .NET/PowerShell만으로 exact
`<RunRoot>\<RunId>\run-state.genesis.json`을 읽고, 1 MiB size limit, UTF-8
without BOM, exact single case-sensitive `source_manifest_checksum` property,
lowercase 64-hex를 검사한다. 그 authority와 현재 manifest checksum이 다르거나
handoff tree와 RunRoot가 겹치면 즉시 차단한다. 이어서 manifest에 기록된
Common/Contract/Files/Runtime module leaf의 checksum과 no-reparse path를
built-in bootstrap으로 검증한 뒤 import한다. Import 후에는
`Read-CgceRunState`, marker 검증, immutable state identity,
`Assert-CgceHandoffSource -ExpectedManifestChecksum
$state.source_manifest_checksum`으로 전체 payload를 다시 검증한다.
Manifest를 payload 변경에 맞춰 다시 작성한 re-signed tree도 immutable
checksum이 달라지므로 import 전에 차단되고 no module side effect가
관찰되어야 한다. 반대로 checksum과 payload bytes가 그대로인 복사본은
same verified bytes may be relocated 규칙에 따라 허용된다.

격리 probe는 UE4SS Lua mod의 공식
`Mods\<ModName>\scripts\main.lua` 구조를 사용한다. UE4SS documentation에 따라
`Mods\mods.txt`의 `CGCEDiscoveryInventory : 1` line으로 활성화한다.

Probe는 다음 UE4SS dumper만 호출한다.

```lua
DumpAllObjects()
GenerateSDK()
```

`DumpAllObjects()`는 `UE4SS_ObjectDump.txt`를 만들고, `GenerateSDK()`는
`CXXHeaderDump`에 C++ headers를 만든다. Probe는 Unreal property를 읽거나
쓰지 않고 candidate function도 호출하지 않는다.

operator는 dump completion marker를 확인한 뒤 서버 콘솔의 정상 shutdown
절차로 test process를 종료한다. script는 timeout 때 production을 자동
재시작하거나 original을 덮어쓰지 않고 `BLOCKED`로 전환한다.

### 4. Restore

`Restore-CgceProduction.ps1`은 PalServer와 listener가 0개임을 다시 확인한다.
state error에 `CGCE-OPS-MANUAL-RECOVERY`가 하나라도 있거나 process journal에
`manual-recovery-required.json`이 있으면 자동 복원은 금지된다. Restore는 lock
아래 intent 생성 전과 모든 mutation 직전에 두 barrier를 다시 검사하고,
어느 하나라도 있으면 state와 filesystem을 바꾸지 않은 채 manual recovery를
요구한다.
active test Saved, probe와 새로 생성된 dump output/`UE4SS.log`를 no-overwrite
quarantine으로 이동하고, inactive original을 active `Saved`로 rename한다.
original inventory와 restored inventory가 같아야 `RESTORED`가 된다.
`mods.txt`와 pre-existing dump outputs/`UE4SS.log`도 exact before-image로
복원한다.

Restore는 Invoke를 dot-source/import/call하지 않고 자체 private built-in-only
bootstrap을 첫 handoff import 전에 실행한다. 자신의 `$PSScriptRoot`에서
handoff root를 도출하고, allocation 전에 length를 검사하는 bounded strict
UTF-8 genesis/manifest reader로 immutable `source_manifest_checksum`을 얻는다.
자신의 `Restore-CgceProduction.ps1` leaf와 exact
Common/Contract/Files/Runtime leaf checksum, no-reparse origin,
handoff/RunRoot 양방향 non-overlap을 검증한다. 같은 이름의 module이 다른
origin에서 preload되어 있으면 import 전에 차단한다. Exact absolute path로
module을 import한 뒤 loaded origin, full current state, marker, genesis
identity와 전체 payload를 다시 검증한다. Byte-identical verified handoff
relocation은 허용하지만 re-signed tree는 어떤 module side effect도 실행하기
전에 차단한다.

#### Production restore journal

Production restore journal은 `receipts\restore` 아래 다음 네 child만 허용한다.
unknown child, directory child, sequence gap, overwrite는 자동 복구를 차단한다.

```text
000-restore-intent.json
010-quarantine-clone.json
020-restore-original.json
999-restore-final.json
```

모든 source/destination state는 기존 Runtime과 같은 exact five-key
`artifact_state`를 사용한다.

```text
artifact_type,present,length,sha256,tree_sha256
```

Directory absent state는
`DIRECTORY,false,null,null,null`, present state는
`DIRECTORY,true,null,null,<lowercase-sha256>`다. `tree_sha256`은 strict sorted
inventory를 기존 domain-separated `CGCE-TREE-1` framing으로 계산한다. 전체
inventory entries는 bounded receipt에 반복하지 않고 authoritative
`inventories\original.json`과 `inventories\restored.json`에만 보존한다.
Operation의 `before_state`와 `after_state`는 exact
`source,destination` pair다.

Task 11A.6은 Runtime-private digest 구현을 Contract-owned pure
`Get-CgceInventoryTreeSha256 -Entries <object[]>`로 승격한다. Contract, Files,
Runtime과 Restore는 이 한 구현만 사용하며 별도 framing 구현을 두지 않는다.
Known vector, entry order, duplicate relative path와 strict entry shape를
Contract test로 고정한다.

`000-restore-intent.json`의 kind는
`cgce_windows_discovery_restore_intent`이며 exact top-level keys는 다음과
같다.

```text
schema_version,kind,run_id,sequence,created_at_utc,
source_state_sha256,source_phase,source_outcome,source_revision,
source_updated_at_utc,source_errors,
genesis_state_sha256,
original_inventory_sha256,original_tree_sha256,
selected_case,paths,steps
```

`paths`의 exact keys는 다음과 같다.

```text
active_saved,inactive_original,quarantined_clone,
original_inventory,restored_inventory,restore_receipts,
probe_restore_final_receipt
```

`steps`는 항상 sequence 순서의 exact two-element array다. 각 item의 exact
keys는 다음과 같다.

```text
sequence,step,operation,source_path,destination_path,
before_state,after_state
```

Fresh `selected_case`는 다음 세 값만 허용한다.

```text
UNCHANGED_ORIGINAL
CLONE_AND_INACTIVE_ORIGINAL
NO_ACTIVE_AND_INACTIVE_ORIGINAL
```

Phase별 fresh case는 다음 matrix로 고정한다.

```text
CREATED:              UNCHANGED_ORIGINAL
BACKUP_VERIFIED:      UNCHANGED_ORIGINAL | NO_ACTIVE_AND_INACTIVE_ORIGINAL
ORIGINAL_DEACTIVATED: NO_ACTIVE_AND_INACTIVE_ORIGINAL |
                      CLONE_AND_INACTIVE_ORIGINAL
CLONE_ACTIVE:         CLONE_AND_INACTIVE_ORIGINAL
PROBE_STAGED:         CLONE_AND_INACTIVE_ORIGINAL
RUNNING:              CLONE_AND_INACTIVE_ORIGINAL
CAPTURED:             CLONE_AND_INACTIVE_ORIGINAL
```

Symbolic `original`, `clone`, `absent`는 각각 intent가 checksum-bound한 exact
directory state다. Case별 fixed step matrix는 다음과 같다.

```text
UNCHANGED_ORIGINAL
  010 QUARANTINE_CLONE / VERIFY_RESTORED
      (active_saved=original, quarantined_clone=absent) -> same
  020 RESTORE_ORIGINAL / VERIFY_RESTORED
      (inactive_original=absent, active_saved=original) -> same

CLONE_AND_INACTIVE_ORIGINAL
  010 QUARANTINE_CLONE / MOVE_DIRECTORY
      (active_saved=clone, quarantined_clone=absent) ->
      (active_saved=absent, quarantined_clone=clone)
  020 RESTORE_ORIGINAL / MOVE_DIRECTORY
      (inactive_original=original, active_saved=absent) ->
      (inactive_original=absent, active_saved=original)

NO_ACTIVE_AND_INACTIVE_ORIGINAL
  010 QUARANTINE_CLONE / VERIFY_ABSENT
      (active_saved=absent, quarantined_clone=absent) -> same
  020 RESTORE_ORIGINAL / MOVE_DIRECTORY
      (inactive_original=original, active_saved=absent) ->
      (inactive_original=absent, active_saved=original)
```

`ORIGINAL_ALREADY_ACTIVE`는 persisted `selected_case`가 아니다. Step 020 뒤
crash-before-receipt layout은 기존 immutable intent, valid `010` prefix,
exact step-020 after-state가 모두 일치할 때만 원래 selected case의 resume
position으로 인정한다.

`010`과 `020` receipt의 kind는
`cgce_windows_discovery_restore_operation`이며 exact keys는 다음과 같다.

```text
schema_version,kind,run_id,sequence,step,operation,
source_path,destination_path,before_state,after_state,
previous_receipt_sha256,completed_at_utc
```

`010.previous_receipt_sha256`은 exact intent checksum이고,
`020.previous_receipt_sha256`은 exact `010` checksum이다.

`999-restore-final.json`의 kind는
`cgce_windows_discovery_restore_final`이며 exact keys는 다음과 같다.

```text
schema_version,kind,run_id,sequence,
restore_intent_sha256,previous_receipt_sha256,
operation_receipts,probe_restore_final_receipt,
original_inventory,restored_inventory,completed_at_utc
```

`previous_receipt_sha256`은 exact `020` checksum이다.
`operation_receipts`는 exact `sequence,path,sha256` keys를 가진 `010`, `020`
binding 두 개다. `original_inventory`와 `restored_inventory`는 exact
`path,sha256,tree_sha256` keys를 가진다. 별도 top-level restored tree
checksum은 두지 않는다. 두 inventory의 semantic entries/tree digest와 fresh
active Saved tree가 모두 일치해야 한다.

`probe_restore_final_receipt`는 `null` 또는 exact `path,sha256` object다.
Source state의 `probe_receipt_checksum`이 `null`일 때만 `null` binding을
허용하며, 이 경우에도 Runtime이 probe intent, probe journal, before-image,
staged/generated residue가 모두 없음을 검증해야 한다. Source state의
`probe_receipt_checksum`이 non-null이면 object binding이 필수다. Object의
path는 derived `999-probe-restore-final.json` path와 같고 `sha256`은 그
파일의 checksum이어야 한다. Runtime은 probe restore intent의
`stage_final_sha256`이 reconstructed source state의
`probe_receipt_checksum`과 같은지, full gapless probe restore journal과
terminal filesystem matrix가 유효한지 의미적으로 다시 검증한다.

#### Recovery mutation authority

Contract의 세 fixed-purpose recovery state writer는 caller boolean이나 callback을
받지 않는다. 각 writer는 fresh state에서 executable allowlist, listener ports,
partial process journal과 manual-recovery barrier를 도출하여 CAS 직전에
module-private inactivity 검사를 직접 수행한다.

Contract는 unexported state-derived
`Assert-CgceRecoveryProbeCompletionAuthority`도 소유한다. 이 validator는
Contract-private read-only filesystem code와 shared tree digest를 사용해
source-bound probe intent/stage/final restore chain을 strict-read하고 probe
terminal filesystem artifact를 fresh inventory한다. Runtime에 의존하지 않으며
Runtime validator와 semantic parity test를 갖는다.
`Complete-CgceRecoveryRunState`는 `RESTORED` CAS 직전에 이를 직접 호출한다.

Runtime은 다음 output-free read-only export를 제공한다.

```powershell
Assert-CgceInventoryProbeRestored `
    -Paths <PSCustomObject> `
    -RunDirectory <string> `
    -RunId <string> `
    [-ExpectedFinalReceiptChecksum <string>] -> void
```

이 validator는 exact no-probe authority 또는 source-bound full gapless probe
restore journal과 fresh terminal filesystem matrix만 허용하고 artifact를
생성·복구·이동·수정하지 않는다. `Restore-CgceInventoryProbe`는 이미 완료된
경로에서 이 validator를 호출한다. Completed marker helper도 active marker
move 또는 completed-only no-op verdict 직전에 이를 호출한다. Contract의
private validator와 Runtime의 이 export는 같은 fixture에서 semantic
allow/block parity를 유지하되 구현을 공유하지 않는다.

Restore-private intent, operation, inventory, final journal, marker helper도 모든
실제 write/move/replace 직전에 같은 state-derived manual barrier와 Runtime
process/listener 검사를 내부에서 다시 수행한다. `Restore-CgceInventoryProbe`
public signature는 바꾸지 않는다. 대신 Runtime module-private guard가 fresh
state/marker/path authority를 재도출하여 restore directory 생성, probe restore
intent, 각 file/directory move, 각 operation receipt와 probe final receipt
직전에 검사한다. `SkipSafety`, caller-provided success boolean, generic recovery
callback은 허용하지 않는다.

기존 state error 또는 process sentinel이 이미 manual recovery를 요구하면
recovery blocker를 포함한 어떤 state/filesystem mutation도 수행하지 않는다.
기존 barrier가 없으면 `ACTIVE` 또는 이미 `BLOCKED`였던 source 모두 initial
RESTORING CAS 뒤 발생한 caught recovery failure를 fixed-purpose blocker로
영속할 수 있다. Blocker는 source errors를 그대로 보존하고 exactly one
normalized `CGCE-OPS-*` error를 revision + 2에 append한다. `ACTIVE` source는
`RESTORING/BLOCKED`로 바뀌고 `BLOCKED` source는 그 outcome을 유지한다. 새
filesystem-layout ambiguity의 normalized code는 반드시
`CGCE-OPS-MANUAL-RECOVERY`다.

Completed marker helper는 exact two-state idempotent contract다. Active-only
layout에서는 fresh RESTORED completion authority와 inactivity를 검증한 뒤
completed marker로 no-overwrite move한다. Completed-only layout에서는 exact
completed marker와 같은 fresh authority를 검증하고 no-op한다. Both 또는
neither layout은 control error다. 두 경로 모두 위 read-only Runtime
validator를 호출하며 probe artifact를 repair하지 않는다. Fresh completion과
completed-only replay 모두 helper가 끝난 뒤 하나의 공통 terminal section에
도달한다. 성공은 stdout에 exactly one
`CGCE_WINDOWS_DISCOVERY_OK RESTORED <run_id>` line과 exit `0`, 실패는 stdout에
exactly one
`CGCE_WINDOWS_DISCOVERY_BLOCKED <stable_error_code> <run_id>` line과 exit `1`을
남긴다. Catch path는 rethrow하거나 추가 stderr terminal을 출력하지 않는다.

복원 성공 후에도 server는 stopped, external-access-blocked 상태를 유지한다.

### 5. Export

`Export-CgceDiscoveryEvidence.ps1`은 `RESTORED`에서만 실행한다. strict
allowlist를 staging하고 각 file의 SHA-256을 export manifest에 기록한 뒤
no-overwrite ZIP과 sidecar를 만든다. exact capture path 밖의
save/config/credential filename이나 structured JSON의 known secret key가
발견되면 export를 중단한다. object/header dump 본문은 private reflection
evidence이므로 property-name 문자열을 secret key로 오인해 검사하지 않는다.

## 테스트

### macOS

1. handoff ZIP을 두 번 만들었을 때 bytes와 sidecar가 같다.
2. ZIP entry가 exact allowlist와 같다.
3. DLL, save, config, private artifact, vendored runtime이 없다.
4. probe source에 write/call/mutation API가 없다.
5. 기존 Lua suite와 Discovery package verification이 계속 통과한다.

### Windows synthetic tree

외부 module 설치 없이 Windows PowerShell `5.1`에서
`tests/windows/Run-CgceDiscoveryTests.ps1`을 실행한다.

1. missing/expired control evidence, incomplete process-path attestation,
   process, listener를 거부한다.
2. reparse point와 root overlap을 거부한다.
3. backup/clone inventory drift를 거부한다.
4. phase skip과 run replay를 거부한다.
5. existing probe/mods line을 overwrite하지 않는다.
6. `-publiclobby`와 secret-bearing argument를 거부한다.
7. synthetic Saved에서 prepare → capture fixture → restore 후 original bytes가 같다.
8. restore 전에 export를 거부한다.
9. export allowlist 밖 save/config/credential을 거부한다.
10. 실패한 clone과 original을 삭제하지 않는다.
11. current state revision이 바뀌어도 immutable genesis marker 검증은
    유지되고 marker/genesis drift는 거부한다.
12. committed state의 missing/null/uppercase/line-suffixed
    `source_manifest_checksum`, genesis/current/CAS drift를 거부한다.
13. handoff module에 sentinel side effect를 추가하고 payload hash와 manifest를
    함께 다시 만든 re-signed tree를 Invoke하면 checksum terminal failure가
    나며 sentinel이 생성되지 않는다(no module side effect). 동일한 verified
    bytes를 다른 handoff root로 옮긴 경우는 허용하고, derived handoff tree와
    RunRoot overlap은 module import 전에 거부한다.
14. Restore intent는 exact source-state preimage, phase/case matrix와 fixed
    010/020 steps만 허용하며 unknown/gapped/foreign receipt를 mutation 전에
    거부한다.
15. 이미 active인 original은 새 selected case로 허용하지 않고, existing
    intent와 valid prefix가 exact operation after-state를 증명할 때만
    crash-before-receipt resume로 인정한다.
16. state-only manual error와 sentinel-only manual barrier가 각각 intent,
    state CAS, directory creation, move, receipt, inventory, final state와
    marker mutation을 모두 차단한다.
17. process/TCP/UDP activity를 각 preceding check 뒤에 주입했을 때 다음
    Contract, Files, Runtime 또는 Restore mutation이 발생하지 않는다.
18. `000`, `010`, `020`, restored inventory, `999`, `RESTORED` state와 marker
    경계마다 crash를 주입한 재실행이 정확한 original을 복원하거나
    `CGCE-OPS-MANUAL-RECOVERY`로 차단하며 original과 backup을 삭제하지 않는다.
19. Restore의 re-signed handoff tree도 module import 전에 차단되어 module
    sentinel side effect가 발생하지 않는다.
20. Restore는 oversized genesis/manifest를 allocation/import 전에 차단하고,
    wrong-origin preloaded handoff module을 거부한다.
21. Restore는 byte-identical verified handoff relocation을 허용하지만
    handoff/RunRoot의 어느 방향 overlap도 import 전에 거부한다.
22. Contract와 Runtime의 activity 및 probe-completion validator는 같은
    process/port/journal/terminal fixture에서 동일한 allow/block verdict를 낸다.
23. Completed-only marker replay는 filesystem/state를 쓰지 않고 exactly one
    RESTORED terminal line을 출력하며, both/neither marker layout을 거부한다.
24. Runtime의 restored-probe validator는 absent와 completed authority를
    read-only로 검증하며, completed marker helper는 이를 호출해도 probe
    artifact를 생성·repair·이동하지 않는다.

### 실제 Windows 서버 진입 조건

1. macOS test와 package verification이 통과한다.
2. Windows synthetic tree suite가 Windows PowerShell `5.1`에서 통과한다.
3. operator가 자동 재시작 중지와 외부 접속 차단을 별도로 확인한다.
4. full Saved backup의 보관 위치와 restore 절차를 operator가 확인한다.
5. 실제 run은 먼저 inventory 1회만 수행하고 Gate A나 mutation 성공으로
   해석하지 않는다.

## 후속 단계

Task 11A의 성공 기준은 restore-verified non-authoritative inventory export다.
이 결과를 사람이 검토한 뒤에만 Task 11B에서 exact probe request, candidate
observation, production read-only composition, fatal-safety proof와 Gate A
acceptance를 별도 설계·구현한다.

Task 11B에서 필요할 수 있는 native file-I/O hardening이나 Windows build
runner는 이 단계의 전제도 산출물도 아니다.

## 참고

- [UE4SS Lua mod structure and `mods.txt`](https://docs.ue4ss.com/guides/creating-a-lua-mod.html)
- [UE4SS installation and working-directory layout](https://docs.ue4ss.com/installation-guide)
- [UE4SS `DumpAllObjects`](https://docs.ue4ss.com/lua-api/global-functions/dumpallobjects.html)
- [UE4SS `GenerateSDK`](https://docs.ue4ss.com/lua-api/global-functions/generatesdk.html)
