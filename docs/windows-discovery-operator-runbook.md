# CGCE Windows Discovery Operator Runbook

> `[IMPLEMENTATION BLOCKED]` 실제 Windows maintenance 실행은 아직 승인되지
> 않았다. 이전 source의 elevated Windows PowerShell `5.1` 결과는 174개 중
> 100개 통과, 74개 실패였다. 호환 수정과 정확히 10개인 operator smoke
> runner는 구현됐지만, 현재 source에 대한 두 Windows gate의 새
> `failures=0` 증거는 아직 없다. 아래 `[READY NOW]` 합성·handoff 검증까지만
> 수행하고 실제 server root, `Saved`, UE4SS 설치에는 접근하지 않는다.

이 문서는 Task 11A의 Windows operator lifecycle만 다룬다. Task 11B의 exact
Palworld symbol 관찰과 Gate A 검토는 `docs/discovery-runbook.md`, 이후 Steam
Windows/PS5/macOS 검증은 `docs/certification-runbook.md`를 사용한다.

## 상태 표기

- `[READY NOW]`: 현재 상태에서 실행해도 실제 서버나 월드를 변경하지 않는다.
- `[IMPLEMENTATION BLOCKED]`: 구현 또는 필수 검증 증거가 없어 진행할 수 없다.
- `[APPROVAL REQUIRED]`: 기술 gate가 통과한 뒤 별도 maintenance 승인이
  필요하다.
- `[STOP]`: 더 진행하지 않고 현재 파일과 증거를 보존한다.

## 현재 상태

| 항목 | 상태 | 완료 조건 |
|---|---|---|
| Task 1–6 prepare/invoke/restore source | 구현됨 | Windows suite 검증 필요 |
| Task 7 private evidence export source | 구현됨 | Windows rejection/resume 검증 필요 |
| Task 8 deterministic handoff source | 구현됨 | tracked-clean source gate 필요 |
| Task 9 full synthetic lifecycle source | 구현됨 | Windows `failures=0` 필요 |
| 전체 Windows 회귀 suite | `[READY NOW]` | 현재 source의 새 실행에서 `failures=0` |
| Operator smoke gate | `[READY NOW]` | 정확히 10개 실행 및 `failures=0` |
| 실제 server maintenance | `[IMPLEMENTATION BLOCKED]` | 두 Windows gate와 별도 사용자 승인 |
| Task 11B / Gate A | `[IMPLEMENTATION BLOCKED]` | 실제 private inventory 검토 |

Source 구현 완료는 Windows 동작 검증 완료를 뜻하지 않는다. 실제 서버 실행,
Gate A, mutation, client 호환성, release 가능성을 주장하지 않는다.

## 역할과 신뢰 경계

- 개발 담당자는 전체 Windows PowerShell `5.1` 회귀 suite를 수정·통과시키고,
  macOS에서 tracked-clean handoff ZIP과 sidecar를 만든다.
- Windows operator는 checksum을 확인하고 별도의 핵심 smoke gate만 실행한다.
- 실제 점검이 승인되면 같은 operator가 자동 재시작 중지, 외부 접속 차단,
  player disconnect와 정상 종료를 직접 확인한다.
- 도구는 firewall, Windows service, scheduler, watchdog을 변경하지 않고
  production server를 시작하거나 외부 접속을 다시 열지 않는다.
- local administrator가 실행 중 파일을 악의적으로 교체하는 경우까지
  방어하지 않는다. 대신 모든 handoff, state, inventory, receipt와 marker를
  checksum-bound로 검증하고 불명확한 상태를 fail closed 처리한다.

## Private artifact 규칙

다음 경로는 access-controlled private storage에만 둔다.

- Windows run root와 whole-`Saved` backup
- inactive original과 quarantined test clone
- UE4SS before-image와 generated-output quarantine
- `CGCE-Windows-Discovery-<run_id>.zip` 및 sidecar
- developer regression/operator smoke/real Windows test transcript

Private evidence ZIP에는 save/config byte가 없지만 inventory relative path/hash와
runtime dump 이름이 world/player 식별 단서가 될 수 있다. 다음 위치에는 올리지
않는다.

- source control
- 공개 issue 또는 discussion
- release archive
- 공개 object storage 또는 chat attachment

## `[READY NOW]` 1. Windows 전체 회귀 진단

이 단계는 개발자/CI용 세부 회귀 suite다. Operator가 실제 maintenance 직전에
전체 세부 test를 반복 실행하는 절차가 아니며, 별도 smoke gate를 대체하지
않는다.

이 단계는 실제 Palworld server가 설치되지 않은 별도 Windows 작업 복사본에서도
실행할 수 있다. 실제 server root, 운영 `Saved`, 실제 UE4SS root를 인자로
전달하지 않는다.

### 준비

1. 현재 source의 exact commit 또는 승인된 private source archive를 Windows
   작업 디렉터리에 복사한다.
2. 전체 경로에 reparse point가 없는지 확인한다.
3. Windows PowerShell `5.1`을 관리자 권한으로 실행한다.
4. PowerShell 버전이 `5.1`인지 기록한다. `pwsh`나 PowerShell `7` 결과로
   대체하지 않는다.

### 실행

저장소 root에서 다음 명령만 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

### 판정

- 마지막 줄이 정확히 `CGCE_WINDOWS_TESTS failures=0`이면 transcript 전체와
  source commit/checksum을 보존한다.
- 2026-07-26 이전 source의 실제 실행 결과
  `CGCE_WINDOWS_TESTS failures=74`는 현재 source의 통과 증거가 아니다.
  호환 수정이 반영된 exact source에서 새 결과를 보존해야 한다.
- `FAIL`, non-zero exit, PowerShell version mismatch, 관리자 권한 부족이 있으면
  `[STOP]`이다.
- 실패한 상태에서 실제 server 경로를 사용하거나 수동으로 state/marker를
  고치지 않는다.

## `[READY NOW]` 2. Operator smoke gate

운영자용 entry point는
`tests/windows/Run-CgceDiscoverySmokeTests.ps1`이다. 저장소 root 또는 검증된
handoff root에서 다음 명령을 Windows PowerShell `5.1`로 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1
```

마지막 줄이 정확히
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`이고 exit code가 `0`일 때만
통과다.

Smoke는 다음 열 가지 대표 동작만 다룬다.

1. PowerShell `5.1`/CLR 4 및 unrelated production activity 격리
2. handoff manifest의 exact sorted payload allowlist
3. 기존 state file handle을 보존하는 run-state replacement
4. Windows volume root와 descendant canonicalization
5. target 이전 junction/reparse point 거부
6. no-overwrite verified tree copy와 exact inventory
7. intent-bound before/after recovery matrix
8. absent/completed authority에 대한 read-only restored validator
9. restore 이후 private export exact allowlist
10. original bytes 복원과 evidence export를 포함한 전체 synthetic lifecycle

Smoke는 실제 production `Saved`, UE4SS 설치, PalServer process 또는 실제
listener를 읽거나 변경하지 않는다. Process/listener 검사는 mock telemetry 또는
실행 시 할당한 임시 port를 사용한다. 따라서 unrelated production 서버가 UDP
`8211`을 정상 사용 중인 사실은 smoke 실패 사유가 아니다.

이 격리는 실제 maintenance의 listener gate를 완화하지 않는다. 승인된
maintenance에서는 production을 정상 종료한 뒤 control evidence에 기록한
실제 port와 모든 server process/descendant가 사라졌는지 반드시 확인한다.
하나라도 남아 있으면 `[STOP]`이다.

전체 회귀 suite는 개발자/CI에서 계속 `failures=0`이어야 하고, operator
smoke도 별도로 `failures=0`이어야 한다.

## `[READY NOW]` 3. macOS handoff 생성

이 단계는 tracked-clean source에서만 성공한다.

```sh
./scripts/verify-discovery-handoff.sh
./scripts/build-discovery-handoff.sh
comparison_directory=$(mktemp -d)
./scripts/build-discovery-handoff.sh \
  "$comparison_directory/CGCE-Windows-Discovery-Handoff.zip"
cmp \
  dist/CGCE-Windows-Discovery-Handoff.zip \
  "$comparison_directory/CGCE-Windows-Discovery-Handoff.zip"
cmp \
  dist/CGCE-Windows-Discovery-Handoff.zip.sha256 \
  "$comparison_directory/CGCE-Windows-Discovery-Handoff.zip.sha256"
```

생성물:

- `dist/CGCE-Windows-Discovery-Handoff.zip`
- `dist/CGCE-Windows-Discovery-Handoff.zip.sha256`

Verifier는 exact allowlist, tracked source, symlink 부재, DLL/save/private
artifact 부재와 forbidden remote-control/mutation token을 검사한다. Builder는
sorted `source-manifest.sha256`, 고정 permission/timestamp, path-independent
sidecar를 만든다.

같은 clean commit에서 서로 다른 임시 디렉터리로 두 번 빌드한 ZIP과 sidecar가
각각 byte-identical이어야 한다. 다르면 `[STOP]`이다.

## `[READY NOW]` 4. Windows handoff 검증

Windows에서 checksum과 source manifest 검증을 완료하기 전에는 handoff 내부
smoke runner를 실행하지 않는다.

검증된 전송 디렉터리를 지정하고 다음 block을 그대로 실행한다. Sidecar도
handoff ZIP과 같은 승인된 전달 경로에서 받은 파일이어야 한다.

```powershell
$transferRoot = "D:\CGCE\Incoming"
$bundle = Join-Path `
    $transferRoot `
    "CGCE-Windows-Discovery-Handoff.zip"
$bundleSidecar = "$bundle.sha256"
$extractionParent = "D:\CGCE\Extracted"
$extractionRoot = Join-Path `
    $extractionParent `
    ("handoff-" + [guid]::NewGuid().ToString("N"))

$sidecarText = [IO.File]::ReadAllText($bundleSidecar)
$sidecarMatch = [regex]::Match(
    $sidecarText,
    '\A([0-9a-f]{64})  CGCE-Windows-Discovery-Handoff\.zip\n\z'
)
if (-not $sidecarMatch.Success) {
    throw "invalid handoff sidecar"
}
$expectedBundleSha256 = $sidecarMatch.Groups[1].Value
$bundleSha256 = (
    Get-FileHash -LiteralPath $bundle -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($bundleSha256 -cne $expectedBundleSha256) {
    throw "handoff checksum mismatch"
}
if (-not (Test-Path `
        -LiteralPath $extractionParent `
        -PathType Container)) {
    throw "handoff extraction parent is missing"
}
if (Test-Path -LiteralPath $extractionRoot) {
    throw "handoff extraction destination exists"
}
Expand-Archive `
    -LiteralPath $bundle `
    -DestinationPath $extractionRoot

$handoffRoot = Join-Path `
    $extractionRoot `
    "CGCE-Windows-Discovery-Handoff"
$sourceManifestPath = Join-Path `
    $handoffRoot `
    "source-manifest.sha256"
$sourceManifestSha256 = (
    Get-FileHash `
        -LiteralPath $sourceManifestPath `
        -Algorithm SHA256
).Hash.ToLowerInvariant()
$contractPath = Join-Path `
    $handoffRoot `
    "tools\windows-discovery\modules\CgceDiscovery.Contract.psm1"
Import-Module $contractPath -Force
Assert-CgceHandoffSource `
    -HandoffRoot $handoffRoot `
    -ManifestPath $sourceManifestPath `
    -ExpectedManifestChecksum $sourceManifestSha256

$ps51 = Join-Path `
    $env:WINDIR `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$smokePath = Join-Path `
    $handoffRoot `
    "tests\windows\Run-CgceDiscoverySmokeTests.ps1"
& $ps51 `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $smokePath
if ($LASTEXITCODE -ne 0) {
    throw "CGCE operator smoke failed"
}
```

`$transferRoot`와 `$extractionParent`만 operator가 확인한 canonical
non-reparse path로 바꾼다. 새 GUID extraction destination을 한 번만 사용한다.
Manifest validator는 exact file set, 각 file checksum,
duplicate/path escape/unknown/missing entry를 모두 거부한다.

Checksum mismatch, 기존 extraction destination, symlink/reparse, manifest
오류, smoke non-zero exit 또는 마지막 줄이 정확히
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`이 아닌 경우는 `[STOP]`이다.
Smoke runner는 handoff exact allowlist에 포함되어 있다. 이 검증 성공만으로
실제 maintenance가 승인되지는 않는다.

## `[IMPLEMENTATION BLOCKED]` 해제 조건

다음 증거가 모두 있어야 실제 명령을 이 문서의 `[APPROVAL REQUIRED]` 실행
block으로 승격할 수 있다.

- macOS full Lua suite 통과
- discovery package verifier 통과
- clean handoff verifier 통과
- 두 clean handoff build의 byte identity
- elevated Windows PowerShell `5.1` full regression suite `failures=0`
- 별도 operator smoke runner의 `failures=0`
- unrelated production `8211`이 실행 중이어도 smoke가 production
  process/port/filesystem에 접근하지 않는다는 격리 증거
- 합성 lifecycle의 original inventory 복원
- backup, quarantined clone, completed marker 보존
- evidence ZIP sidecar/manifest 검증 및 save/config/credential 부재

현재 문서에는 실제 server에 복사 실행할 수 있는 prepare/invoke/restore/export
명령 block을 의도적으로 싣지 않는다.

## `[APPROVAL REQUIRED]` 실제 maintenance 사전 조건

위 차단 조건을 모두 해제한 뒤에도 사용자의 별도 maintenance 승인이 필요하다.
승인은 다음 exact 대상을 포함해야 한다.

- Windows host와 canonical server root
- canonical `Pal\Saved` 및 UE4SS root
- whole-`Saved` backup을 둘 별도 run volume
- fresh `r-` + 32 lowercase hex run ID
- fresh `m-` + 32 lowercase hex maintenance ID
- exact handoff ZIP checksum과 source-manifest checksum
- 점검 시작/종료 시간과 operator

실제 maintenance용 별도 포트는 요구하지 않는다. 대신 production과 test
clone이 같은 configured port를 순차 사용하며, production 자동 재시작이 꺼져
있고 외부 ingress가 차단되어 있어야 한다. Prepare 전에 production을 정상
종료하고 해당 port의 listener가 사라졌음을 확인한다. 이 실제 listener 검사는
synthetic smoke의 임시 port 정책과 별개다.

## Control evidence 작성

`control-evidence.json`은 UTF-8 JSON object이며
`tools/windows-discovery/schemas/control-evidence.schema.json`의 exact key set을
따른다.

Operator는 다음을 직접 검토한다.

1. `server_root`, `palserver_executable`, `ue4ss_root`를 canonical absolute
   Windows path로 기록한다.
2. `UE4SS.dll` 실제 SHA-256과 version `3.0.1`을 기록한다.
3. launcher, PalServer, crash reporter와 server가 만들 수 있는 모든 descendant
   executable의 exact canonical path를 열거한다.
4. 목록이 exhaustive하다고 검토한 뒤에만
   `server_process_paths_complete=true`를 기록한다.
5. 모든 TCP/UDP listener port를 중복 없이 기록한다.
6. 자동 재시작 중지, 외부 접속 차단, player disconnect를 직접 확인한 뒤
   세 boolean을 `true`로 기록한다.
7. `verified_at_utc`부터 최대 4시간 이내의 `valid_until_utc`를 사용한다.
8. handoff ZIP 실제 checksum을 `bundle_checksum`으로 기록한다.
9. 완성된 control evidence 파일 자체의 SHA-256을 별도로 계산해 prepare
   인자로 사용한다.

알 수 없는 descendant image, path 누락 가능성, listener 불명확성, stale
validity window는 `[STOP]`이다. 추측으로 allowlist를 완성하지 않는다.

## Server argument JSON 작성

Argument 파일은 string만 포함하는 dense JSON array다.

- 실제 server executable은 배열에 넣지 않는다.
- 공백을 포함한 한 argument도 하나의 JSON string으로 기록한다.
- admin/server/RCON password, REST API key, private key를 넣지 않는다.
- public advertising 또는 외부 연결을 다시 여는 argument를 넣지 않는다.
- shell command string, redirection, environment expansion을 넣지 않는다.
- 검토한 isolated inventory run에 필요한 비밀이 아닌 argument만 유지한다.

Argument 파일은 private control storage에 두고 source control이나 evidence
ZIP에 넣지 않는다.

## 실제 lifecycle 인터페이스

Windows gate가 통과한 뒤 추가될 실행 block은 다음 순서를 바꿀 수 없다.

1. `Prepare-CgceDiscovery.ps1`
   - server/saved/UE4SS/run canonical path
   - fresh run ID
   - verified handoff/manifest
   - exact control evidence 파일과 checksum
   - handoff ZIP checksum
2. `Invoke-CgceDiscovery.ps1`
   - 같은 run root/run ID
   - exact server executable
   - reviewed argument JSON
   - 최대 1800초 timeout
3. dump marker 확인 후 test server 정상 종료
4. `Restore-CgceProduction.ps1`
   - 같은 run root/run ID만 사용
5. restored inventory와 UE4SS before-image 검증
6. `Export-CgceDiscoveryEvidence.ps1`
   - 같은 run root/run ID
   - 별도 private output directory
7. 개발 호스트에서 ZIP/sidecar/manifest 재검증

Prepare 전에 운영 server와 listener는 모두 없어야 한다. Invoke는 inactive
original이 아닌 verified clone만 active `Saved`로 둔 상태에서 server를 한 번
시작한다. Restore 전에 root와 모든 observed descendant process 및 listener가
종료되어야 한다.

## Export 동작

Exporter는 네트워크 전송 도구가 아니라 local private archive builder다.

실행 조건:

- phase `RESTORED`
- outcome `ACTIVE`
- error 없음
- completed marker만 존재
- original/backup/clone/restored inventory checksum 일치
- capture inventory와 live capture tree 일치
- control evidence가 아직 유효하고 current state에 exact binding됨
- output root가 handoff/run/server root와 겹치지 않음

포함 항목:

- `control-evidence.json`
- export 직전 `RESTORED` `run-state.json`
- four inventory JSON
- `capture/UE4SS_ObjectDump.txt`
- `capture/CXXHeaderDump/**`
- `export-manifest.json`

제외 항목:

- `Saved`, `.sav`, `.ini`, `mods.txt`
- password, API key, private key field
- run directory 밖의 source
- allowlist 밖의 capture entry

ZIP과 sidecar를 다시 읽어 검증한 뒤에만 local state가
`EXPORTED/SUCCEEDED`가 된다. Archive 생성 후 state commit 전에 중단되었다면
`-Resume`은 existing ZIP, sidecar, manifest와 archived `RESTORED` state가 모두
현재 control/state/inventory/capture payload의 exact path, length, checksum과
일치할 때만 전이를 끝낸다. 결과가 다르면 덮어쓰지 않고 `[STOP]`한다.

## 단계별 복구

모든 복구에서 자동 재시작과 외부 접속 차단을 유지하고, PalServer와
allowlisted descendant/listener가 모두 종료됐는지 먼저 확인한다.

| 관찰 상태 | 허용되는 다음 행동 |
|---|---|
| state/genesis 없음 | 운영 원본이 active인지 검증하고 새 run을 시작하지 말고 원인을 조사 |
| `CREATED`–`CAPTURED` | 동일 run ID로 Restore entry point만 사용 |
| `RESTORING` | 동일 recovery intent/receipt prefix로 Restore resume |
| `RESTORED` + active marker | Restore replay로 completed marker 전환 검증 |
| `RESTORED` + completed marker | Export 또는 exact archive `-Resume` |
| `EXPORTED/SUCCEEDED` | archive 검증만 수행; lifecycle 재실행 금지 |
| `BLOCKED` | server를 시작하지 말고 동일 run의 explicit Restore만 시도 |
| manual-recovery error | 자동 조작 중지; backup/original/quarantine/receipt 전체 보존 |

Restore가 `CGCE-OPS-MANUAL-RECOVERY`로 끝나면 filesystem을 수동 rename하거나
receipt/state JSON을 편집하지 않는다. 현재 tree inventory와 receipt chain을
보존해 개발 환경에서 원인을 분석한다.

## `[STOP]` 조건

다음 중 하나라도 발생하면 더 진행하지 않는다.

- handoff, manifest, state, marker, inventory, receipt checksum mismatch
- source/run/output root overlap 또는 reparse point
- 자동 재시작 중지나 외부 접속 차단을 증명할 수 없음
- player가 남아 있음
- control evidence가 만료되었거나 4시간을 초과함
- unlisted/unknown descendant executable
- configured TCP/UDP listener가 남아 있음
- backup/clone/original inventory mismatch
- capture marker 부재, 중복 또는 blocked marker
- active original/test clone/quarantine layout이 모호함
- restored `Saved` 또는 UE4SS before-image mismatch
- exporter가 sensitive/unallowlisted entry를 발견함

`[STOP]`에서는 backup, inactive original, clone, quarantine, receipt, partial
private export를 삭제하거나 덮어쓰지 않는다.

## 운영 복귀

다음을 모두 확인한 뒤 operator가 별도로 복귀 여부를 결정한다.

- active `Pal\Saved`가 pre-run original inventory와 일치
- whole-`Saved` backup이 존재하고 검증 가능
- quarantined test clone이 보존됨
- UE4SS mod/config/output before-image가 복원됨
- active marker가 없고 exact completed marker가 존재
- 모든 process/descendant/listener가 없음
- private evidence ZIP과 sidecar가 개발 호스트에서도 검증됨

도구는 자동 재시작, firewall/ingress, service를 다시 활성화하지 않는다.

## Task 11B handoff

Private object/header inventory는 non-authoritative Task 11B 입력이다. 개발
호스트에서 exact type/function 후보를 검토하기 전에는 다음을 하지 않는다.

- Palworld class/property/function 이름 추측 또는 fuzzy match
- binding manifest 작성
- Gate A acceptance 생성
- UObject write, `TArray` resize/append, dirty/replication 호출
- PS5/macOS/Steam Windows 호환 또는 release 주장

## Gate A 이후 기능 수용 계획

이 절은 현재 Task 11A에서 실행하는 절차가 아니다. Exact symbol Gate A와 별도
mutation 승인이 끝난 뒤 `docs/certification-runbook.md`에서 수행할 최소
whole-`Saved` clone 수용 범위를 설명한다.

실제 Palworld save 형식을 손으로 만들거나 개별 `.sav`를 직접 편집하지 않는다.
운영 서버를 정상 종료한 한 시점의 `Pal\Saved` 전체를 복제하고 실제 PalServer가
그 폐기 가능한 clone만 사용하게 한다.

최소 수용 조건은 다음과 같다.

1. 이미 초기화된 모든 대상 길드 상자가 승인된 목표 슬롯 수로 증가한다.
2. 신규 길드 상자는 Container ID 초기화 후 같은 migration을 적용했을 때 목표
   슬롯 수가 된다.
3. 기존 slot index, item static ID, dynamic GUID, quantity,
   durability/quality/instance metadata, container ID와 owner guild ID가
   동일하며 새 슬롯은 모두 비어 있다.
4. 일반 상자를 포함한 길드 외 컨테이너는 변경되지 않는다.
5. 정상 저장·종료·재시작 후 슬롯과 데이터 불변조건이 유지된다.

현재 설계는 global chest preset의 직접 수정을 전제로 하지 않는다. 신규 길드도
실제 chest container가 초기화된 뒤 기존 길드와 같은 migration engine을
사용한다. 이 다섯 조건은 전체 제품 동작의 최소 수용 범위이며, Phase 1 Alpha와
Phase 3 New Guild Automation의 완료 조건을 하나로 축소하지 않는다. 이후
Steam Windows, PS5, macOS certification은 여전히 별도 release gate다.
