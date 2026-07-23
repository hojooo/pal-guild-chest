# CGCE Windows Discovery Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 컴파일이나 별도 build runner 없이 Windows PowerShell `5.1`로 운영
`Saved`를 백업·분리하고, clone에서 UE4SS inventory probe를 실행한 뒤 원본을
복원하고 private evidence ZIP을 생성한다.

**Architecture:** macOS shell builder는 tracked allowlisted
PowerShell/Lua/test/schema source만 결정론적인 handoff ZIP으로 만든다. Windows
entry point는 contract, filesystem, runtime 모듈을 공유하고 `run-state.json`의
단방향 phase로 prepare, invoke, restore, export를 분리한다. Task 11A 결과는
restore-verified non-authoritative inventory이며 production bootstrap,
Gate A, fatal harness, mutation은 계속 차단한다.

**Tech Stack:** POSIX `sh`, `zip`, `shasum -a 256`, Lua `5.4.8` test runtime,
Windows PowerShell `5.1`, .NET Framework cmdlets, UE4SS `3.0.1` Lua mod,
plain-PowerShell synthetic tests.

## Global Constraints

- 구현 기준 spec은
  `docs/superpowers/specs/2026-07-23-cgce-windows-discovery-operator-stage-design.md`다.
- Windows 64-bit Palworld Dedicated Server와 UE4SS `3.0.1`만 지원한다.
- 별도 port 없이 운영 server와 test process를 직렬 실행한다.
- firewall, service, watchdog, scheduler, external access rule은 변경하지 않는다.
- `Pal\Saved` 전체 verified backup 없이는 active path를 변경하지 않는다.
- 운영 original은 inactive path에 보존하고 test clone만 active `Saved`로 쓴다.
- DLL, compiler, Pester/module install, WinRM/SSH, cloud transfer를 요구하지 않는다.
- probe는 `DumpAllObjects()`와 `GenerateSDK()`만 호출한다.
- UObject property write, candidate invocation, `TArray` mutation, resize, append,
  dirty, replication, `ExecuteInGameThread`를 추가하지 않는다.
- production `main.lua`의 `CGCE-LOADER-COMPOSITION-UNAVAILABLE` 차단을 유지한다.
- Task 11A export는 Gate A authority, mutation authority 또는 release evidence가 아니다.
- 실제 save, credential, server password, administrator/RCON/REST secret은
  source, test fixture, handoff ZIP, evidence ZIP에 넣지 않는다.
- immutable artifact output은 no-overwrite이며 실패 시 original, backup,
  clone을 보존한다. `run-state.json`만 checksum compare-and-swap으로 교체하고
  server-global lock file은 OS handle ownership에 재사용한다.
- PowerShell-only atomic replace와 read-back은 process crash/replay를 다루지만
  전원 상실 시 directory-entry durability까지 보장하지 않는다. 모호한
  power-loss 상태는 자동 추론하지 않고 manual recovery로 차단한다.
- 실제 server 실행 전 macOS suite와 Windows PowerShell `5.1` synthetic suite가
  모두 통과해야 한다.

## Approved Interfaces

### PowerShell module surface

```powershell
Read-CgceJsonObject -Path <string> -> PSCustomObject
Read-CgceJsonStringArray -Path <string> -> string[]
Get-CgceSha256 -Path <string> -> lowercase string
Assert-CgceControlEvidence -EvidencePath <string> -ExpectedFileChecksum <string> -ExpectedBundleChecksum <string> -NowUtc <DateTime> -> PSCustomObject
Assert-CgceHandoffSource -HandoffRoot <string> -ManifestPath <string> -> void
New-CgceRunState -RunId <string> -MaintenanceId <string> -Paths <PSCustomObject> -> PSCustomObject
Read-CgceRunState -RunRoot <string> -RunId <string> -> PSCustomObject
Set-CgceRunPhase -State <PSCustomObject> -ExpectedPhase <string> -NextPhase <string> -> PSCustomObject
Write-CgceJsonAtomic -Value <object> -Path <string> [-ExpectedExistingSha256 <string>] -> void
Write-CgceRunState -State <PSCustomObject> -StatePath <string> -ExpectedPhase <string> -> void
Enter-CgceExclusiveLock -ServerRoot <string> -RunId <string> -> FileStream

Resolve-CgceCanonicalPath -Path <string> -MustExist <bool> -> string
Assert-CgceEqualCanonicalPath -Expected <string> -Actual <string> -> void
Assert-CgcePathContainedBy -Path <string> -Root <string> -> void
Assert-CgceDistinctRoots -Paths <string[]> -> void
Assert-CgceNoReparseInPath -Path <string> -> void
Assert-CgceTreeHasNoReparsePoints -Root <string> -> void
New-CgceRunPaths -ServerRoot <string> -SavedPath <string> -Ue4ssRoot <string> -RunRoot <string> -RunId <string> -> PSCustomObject
Get-CgceTreeInventory -Root <string> -> object[]
Compare-CgceInventory -Expected <object[]> -Actual <object[]> -> void
Write-CgceInventory -Entries <object[]> -Path <string> -Kind <string> -> lowercase checksum
Read-CgceInventory -Path <string> -ExpectedKind <string> -> object[]
Copy-CgceFileVerified -Source <string> -Destination <string> -> PSCustomObject
Copy-CgceTreeVerified -Source <string> -Destination <string> -> object[]
Move-CgceDirectoryNoOverwrite -Source <string> -Destination <string> -> void
Assert-CgceRecoveryMatrix -State <PSCustomObject> [-Intent <PSCustomObject>] -> PSCustomObject

Assert-CgceNoServerActivity -ExecutablePaths <string[]> -Ports <int[]> [-ReceiptRoot <string>] -> void
Assert-CgceNoForeignRunArtifacts -ServerRoot <string> -Ue4ssRoot <string> -RunId <string> -> void
Assert-CgceRunMarker -State <PSCustomObject> [-AllowCompleted] -> void
Assert-CgceServerArguments -Arguments <string[]> -> void
Enable-CgceInventoryProbe -Ue4ssRoot <string> -ProbeSource <string> -RunDirectory <string> -RunId <string> -Paths <PSCustomObject> -> PSCustomObject
Restore-CgceInventoryProbe -Paths <PSCustomObject> -RunDirectory <string> -RunId <string> [-ExpectedFinalReceiptChecksum <string>] -> void
Invoke-CgceChildProcess -Executable <string> -ExpectedExecutableChecksum <string> -AllowedExecutablePaths <string[]> -Arguments <string[]> -ReceiptRoot <string> -TimeoutSeconds <int> -> PSCustomObject
```

### Entry points

```powershell
Prepare-CgceDiscovery.ps1
Invoke-CgceDiscovery.ps1
Restore-CgceProduction.ps1
Export-CgceDiscoveryEvidence.ps1
```

Every entry point accepts `-RunRoot`, `-RunId`, and exact input paths, imports
only repository-owned modules, begins with `#Requires -Version 5.1` and
`#Requires -RunAsAdministrator`, uses `$ErrorActionPreference = "Stop"`, and
assigns or suppresses every helper return value so its success stream emits
exactly one terminal line:

```text
CGCE_WINDOWS_DISCOVERY_OK <phase> <run_id>
```

or:

```text
CGCE_WINDOWS_DISCOVERY_BLOCKED <stable_error_code> <run_id>
```

## File Map

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
scripts/
├── verify-discovery-handoff.sh
└── build-discovery-handoff.sh
tests/
├── integration/discovery_handoff_spec.lua
└── windows/
    ├── TestHarness.ps1
    ├── Contract.Tests.ps1
    ├── Files.Tests.ps1
    ├── Runtime.Tests.ps1
    ├── Lifecycle.Tests.ps1
    ├── Run-CgceDiscoveryTests.ps1
    └── fixtures/FakePalServer.cmd
docs/
├── windows-discovery-operator-runbook.md
├── superpowers/specs/2026-07-23-cgce-windows-discovery-operator-stage-design.md
└── superpowers/plans/2026-07-22-cgce-implementation.md
```

---

### Task 1: PowerShell test harness and strict control/state contracts

**Purpose:** 외부 module 설치 없이 Windows PowerShell `5.1`에서 RED/GREEN을
실행하고, 모든 entry point가 공유할 control evidence와 phase contract를
고정한다.

**Files:**
- Create: `tests/windows/TestHarness.ps1`
- Create: `tests/windows/Run-CgceDiscoveryTests.ps1`
- Create: `tests/windows/Contract.Tests.ps1`
- Create: `tools/windows-discovery/modules/CgceDiscovery.Contract.psm1`
- Create: `tools/windows-discovery/CgceDiscovery.Common.psm1`
- Create: `tools/windows-discovery/schemas/control-evidence.schema.json`
- Create: `tools/windows-discovery/schemas/run-state.schema.json`

**Interfaces:**
- Produces: contract module functions listed in `Approved Interfaces`.
- Produces phases:
  `CREATED,BACKUP_VERIFIED,ORIGINAL_DEACTIVATED,CLONE_ACTIVE,PROBE_STAGED,RUNNING,CAPTURED,RESTORING,RESTORED,EXPORTED`.
- Error codes:
  `CGCE-OPS-JSON`, `CGCE-OPS-CHECKSUM`, `CGCE-OPS-CONTROL`,
  `CGCE-OPS-CONTROL-EXPIRED`, `CGCE-OPS-ID`, `CGCE-OPS-PHASE`,
  `CGCE-OPS-OUTPUT-EXISTS`.

- [ ] **Step 1: Create the minimal test harness and failing contract tests**

```powershell
# tests/windows/TestHarness.ps1
$script:CgceFailures = 0
function Invoke-CgceTest([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Output "PASS $Name"
    } catch {
        $script:CgceFailures += 1
        Write-Output "FAIL $Name`n$($_.Exception.Message)"
    }
}
function Assert-CgceEqual($Expected, $Actual) {
    if ($Expected -ne $Actual) {
        throw "expected=[$Expected] actual=[$Actual]"
    }
}
function Assert-CgceThrows([string]$Code, [scriptblock]$Body) {
    try { & $Body } catch {
        if ($_.Exception.Message -like "$Code*") { return }
        throw "expected error $Code but got $($_.Exception.Message)"
    }
    throw "expected error $Code but no error was thrown"
}
```

`Run-CgceDiscoveryTests.ps1` dot-sources `TestHarness.ps1` and an exact ordered
test list—never wildcard-discovered scripts. Task 1 starts with only
`Contract.Tests.ps1`; later tasks append their named file when it is created.

```powershell
$tests = @(
    "Contract.Tests.ps1"
)
foreach ($test in $tests) { . (Join-Path $PSScriptRoot $test) }
Write-Output "CGCE_WINDOWS_TESTS failures=$script:CgceFailures"
if ($script:CgceFailures -ne 0) { exit 1 }
exit 0
```

```powershell
# tests/windows/Contract.Tests.ps1
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1" -Force

Invoke-CgceTest "accepts only fixed run ids" {
    Assert-CgceEqual $true (Test-CgceRunId "r-0123456789abcdef0123456789abcdef")
    Assert-CgceEqual $false (Test-CgceRunId "..\escape")
}

Invoke-CgceTest "rejects skipped phases" {
    $state = [pscustomobject]@{ phase = "CREATED"; outcome = "ACTIVE" }
    Assert-CgceThrows "CGCE-OPS-PHASE" {
        Set-CgceRunPhase -State $state -ExpectedPhase "BACKUP_VERIFIED" -NextPhase "CLONE_ACTIVE"
    }
}
```

- [ ] **Step 2: Run RED on Windows PowerShell 5.1**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Expected: non-zero; import of `CgceDiscovery.Contract.psm1` fails.

- [ ] **Step 3: Implement strict identifiers, checksum, JSON, phase transition, and atomic JSON write**

```powershell
# tools/windows-discovery/modules/CgceDiscovery.Contract.psm1
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:CgceNextPhase = @{
    CREATED = "BACKUP_VERIFIED"
    BACKUP_VERIFIED = "ORIGINAL_DEACTIVATED"
    ORIGINAL_DEACTIVATED = "CLONE_ACTIVE"
    CLONE_ACTIVE = "PROBE_STAGED"
    PROBE_STAGED = "RUNNING"
    RUNNING = "CAPTURED"
    CAPTURED = "RESTORING"
    RESTORING = "RESTORED"
    RESTORED = "EXPORTED"
}

function Test-CgceRunId([string]$Value) {
    return $Value -match '^r-[0-9a-f]{32}$'
}

function Get-CgceSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CGCE-OPS-CHECKSUM missing file"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-CgceJsonObject([string]$Path) {
    $parsed = Read-CgceStrictJsonDocument -Path $Path
    if ($parsed.RootKind -ne "Object") {
        throw "CGCE-OPS-JSON root must be an object"
    }
    return $parsed.Value
}

function Read-CgceJsonStringArray([string]$Path) {
    $parsed = Read-CgceStrictJsonDocument -Path $Path
    if ($parsed.RootKind -ne "Array") {
        throw "CGCE-OPS-JSON root must be an array"
    }
    foreach ($value in $parsed.Value) {
        if ($value -isnot [string]) {
            throw "CGCE-OPS-JSON array values must be strings"
        }
    }
    return [string[]]$parsed.Value
}

function Set-CgceRunPhase($State, [string]$ExpectedPhase, [string]$NextPhase) {
    if ($State.phase -ne $ExpectedPhase -or $script:CgceNextPhase[$ExpectedPhase] -ne $NextPhase) {
        throw "CGCE-OPS-PHASE invalid transition"
    }
    $State.phase = $NextPhase
    return $State
}

function Write-CgceJsonAtomic(
    $Value,
    [string]$Path,
    [string]$ExpectedExistingSha256 = ""
) {
    $parent = Split-Path -Parent $Path
    $temp = Join-Path $parent ((Split-Path -Leaf $Path) + ".tmp")
    if (Test-Path -LiteralPath $temp) { throw "CGCE-OPS-OUTPUT-EXISTS temp exists" }
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        if ($ExpectedExistingSha256 -eq "" -or
            (Get-CgceSha256 -Path $Path) -ne $ExpectedExistingSha256) {
            throw "CGCE-OPS-CHECKSUM compare-and-swap mismatch"
        }
        [System.IO.File]::Replace($temp, $Path, $null, $true)
    } else {
        if ($ExpectedExistingSha256 -ne "") {
            throw "CGCE-OPS-CHECKSUM expected existing file"
        }
        Move-Item -LiteralPath $temp -Destination $Path
    }
}

Export-ModuleMember -Function @(
    "Test-CgceRunId",
    "Get-CgceSha256",
    "Read-CgceJsonObject",
    "Read-CgceJsonStringArray",
    "Assert-CgceControlEvidence",
    "Assert-CgceHandoffSource",
    "New-CgceRunState",
    "Read-CgceRunState",
    "Set-CgceRunPhase",
    "Write-CgceJsonAtomic",
    "Write-CgceRunState",
    "Enter-CgceExclusiveLock"
)
```

`Read-CgceStrictJsonDocument` is a private, bounded RFC 8259 parser implemented
in the contract module. Do not implement it with `ConvertFrom-Json`: Windows
PowerShell 5.1 collapses one-element arrays and loses duplicate-key evidence.
The parser must preserve root kind, use ordinal case-sensitive object keys,
reject duplicate keys, invalid UTF-8/surrogates, non-standard numbers,
excessive depth/size, and trailing input. Add tests for `{}`, `[{}]`, `"x"`,
`["x"]`, duplicate/case-variant keys, one-element argument arrays, and malformed
UTF-8.

The final implementation must use `ExpectedExistingSha256` only for
compare-and-swap replacement of an already validated `run-state.json`.
`Write-CgceRunState` must re-read the on-disk state, validate `run_id`,
`maintenance_id`, schema, and `ExpectedPhase`, then pass the old file checksum
to `Write-CgceJsonAtomic`. It must re-open the replaced file, parse it, and
verify the expected revision/phase/checksum before returning. No other output
path may be overwritten. Add crash-point tests for an existing temp file,
checksum drift, initial create, successful state replacement, and failed
read-back; no test may observe a delete-before-replace gap. Raw output must not
begin with the UTF-8 BOM bytes `EF BB BF`.

- [ ] **Step 4: Add exact JSON schema fixtures and control-evidence validation**

Use exact keys:

```json
{
  "schema_version": "1.0",
  "kind": "cgce_windows_discovery_control",
  "maintenance_id": "m-0123456789abcdef0123456789abcdef",
  "run_id": "r-0123456789abcdef0123456789abcdef",
  "operator": "operator",
  "server_root": "D:\\PalServer",
  "palserver_executable": "D:\\PalServer\\PalServer.exe",
  "server_process_paths": [
    "D:\\PalServer\\PalServer.exe",
    "D:\\PalServer\\Pal\\Binaries\\Win64\\PalServer-Win64-Test-Cmd.exe"
  ],
  "server_process_paths_complete": true,
  "ue4ss_root": "D:\\PalServer\\Pal\\Binaries\\Win64",
  "ue4ss_version": "3.0.1",
  "ue4ss_dll_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "listener_ports": [8211, 27015],
  "production_restart_disabled": true,
  "external_access_blocked": true,
  "players_disconnected": true,
  "bundle_checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "verified_at_utc": "2026-07-23T00:00:00Z",
  "valid_until_utc": "2026-07-23T04:00:00Z"
}
```

`Assert-CgceControlEvidence` must hash `EvidencePath` itself before parsing and
require the exact key set, both fixed ID grammars, non-empty operator/path
fields, a unique non-empty `server_process_paths` array containing the exact
launcher path and the exhaustive executable-image set that the server may
launch, `server_process_paths_complete=true`, every listed path contained by
`server_root`, exact `ue4ss_version=3.0.1`, a 64-hex UE4SS DLL checksum, unique
ports `1..65535`, all four booleans `true`, exact bundle/file checksum, strict
UTC timestamps, and a valid window no longer than four hours. The operator
must not attest completeness until launcher, server child, crash reporter, and
any other server-owned descendant image paths have been reviewed.

Define `run-state.schema.json` with `additionalProperties=false` at every
object level. Its exact top-level keys are:

```text
schema_version,kind,revision,run_id,maintenance_id,phase,outcome,
created_at_utc,updated_at_utc,bundle_checksum,control_evidence_checksum,
palserver_executable,palserver_executable_checksum,ue4ss_version,
server_process_paths,ue4ss_dll_checksum,listener_ports,paths,inventory_checksums,
probe_receipt_checksum,process_launch_receipt_checksum,
process_result_receipt_checksum,capture_inventory_checksum,
errors
```

All keys are always present; not-yet-produced receipt/checksum values are
`null`. `revision` starts at `0` and increments exactly once per successful
compare-and-swap state replacement. `inventory_checksums` has exact keys
`original,backup,clone,restored`. The `paths` object has these exact keys:

```text
server_root,run_root,run_directory,state,genesis_state,control_evidence,
active_run_marker,completed_run_marker,
active_saved,inactive_original,quarantined_clone,backup_saved,
original_inventory,backup_inventory,clone_inventory,restored_inventory,
ue4ss_root,ue4ss_dll,mods_txt,mods_original,mods_test,
probe_staged,probe_quarantine,
object_dump,object_dump_original,object_dump_quarantine,
cxx_header_dump,cxx_header_dump_original,cxx_header_dump_quarantine,
ue4ss_log,ue4ss_log_original,ue4ss_log_quarantine,capture,
probe_intent,probe_receipt,probe_receipts,process_launch_receipt,process_result_receipt,
process_receipts,capture_inventory,restore_receipts
```

Validators reject unknown fields, missing fields, phase-incompatible non-null
receipts, ID/checksum drift, and non-monotonic revision.

The active marker binds RunId, RunRoot, and the checksum of immutable
`genesis_state`; it never claims to hash the mutable current `run-state.json`.
`Assert-CgceRunMarker` validates marker/genesis/current-state identity fields
and re-hashes the immutable genesis snapshot on every entry point.

`Enter-CgceExclusiveLock` opens `<ServerRoot>\.cgce-discovery.lock` with
`FileShare.None`. Every entry point holds that handle from its first validated
state read through its terminal state write. Invoke/restore/export re-read and
revalidate the state after acquiring the lock. The persistent lock filename is
the sole overwrite exemption; OS handle ownership, not file contents, is the
lock. Add a two-process test proving a concurrent entry point blocks without a
filesystem mutation.

- [ ] **Step 5: Run GREEN and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Expected: all contract tests print `PASS`; exit `0`.

Commit:

```bash
git add tools/windows-discovery tests/windows
git commit -m "feat: define Windows discovery contracts"
```

---

### Task 2: Verified filesystem inventory and no-overwrite tree operations

**Purpose:** Saved backup, clone, quarantine, restore가 같은 bytes를 보존했음을
sorted inventory로 증명한다.

**Files:**
- Create: `tests/windows/Files.Tests.ps1`
- Create: `tools/windows-discovery/modules/CgceDiscovery.Files.psm1`
- Modify: `tools/windows-discovery/CgceDiscovery.Common.psm1`
- Modify: `tests/windows/Run-CgceDiscoveryTests.ps1`

**Interfaces:**
- Consumes: contract checksum and atomic JSON functions.
- Produces: filesystem functions listed in `Approved Interfaces`, including one
  deterministic source of truth for every run path.
- Error codes:
  `CGCE-OPS-PATH`, `CGCE-OPS-PATH-OVERLAP`, `CGCE-OPS-REPARSE`,
  `CGCE-OPS-COPY`, `CGCE-OPS-INVENTORY`, `CGCE-OPS-DESTINATION-EXISTS`.

- [ ] **Step 1: Write failing inventory, overlap, reparse, and copy tests**

```powershell
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Files.psm1" -Force

Invoke-CgceTest "inventory is relative and sorted" {
    $root = Join-Path $env:TEMP ("cgce-files-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path (Join-Path $root "b") | Out-Null
    Set-Content -LiteralPath (Join-Path $root "b\2.txt") -Value "two" -NoNewline
    Set-Content -LiteralPath (Join-Path $root "1.txt") -Value "one" -NoNewline
    $items = @(Get-CgceTreeInventory -Root $root)
    Assert-CgceEqual "1.txt" $items[0].relative_path
    Assert-CgceEqual "b/2.txt" $items[1].relative_path
}

Invoke-CgceTest "rejects nested roots" {
    Assert-CgceThrows "CGCE-OPS-PATH-OVERLAP" {
        Assert-CgceDistinctRoots -Paths @("D:\Pal", "D:\Pal\Saved")
    }
}

Invoke-CgceTest "derives every run path from fixed roots and run id" {
    $paths = New-CgceRunPaths `
        -ServerRoot "D:\PalServer" `
        -SavedPath "D:\PalServer\Pal\Saved" `
        -Ue4ssRoot "D:\PalServer\Pal\Binaries\Win64" `
        -RunRoot "E:\CGCE-Private-Runs" `
        -RunId "r-0123456789abcdef0123456789abcdef"
    Assert-CgceEqual `
        "D:\PalServer\Pal\Saved.cgce-original-r-0123456789abcdef0123456789abcdef" `
        $paths.inactive_original
    Assert-CgceEqual `
        "E:\CGCE-Private-Runs\r-0123456789abcdef0123456789abcdef\run-state.json" `
        $paths.state
    Assert-CgceEqual `
        "E:\CGCE-Private-Runs\r-0123456789abcdef0123456789abcdef\receipts\restore" `
        $paths.restore_receipts
    Assert-CgceEqual `
        "E:\CGCE-Private-Runs\r-0123456789abcdef0123456789abcdef\receipts\probe\000-probe-intent.json" `
        $paths.probe_intent
}
```

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: missing filesystem module.

- [ ] **Step 3: Implement canonical paths, reparse rejection, and inventory**

```powershell
function Resolve-CgceCanonicalPath([string]$Path, [bool]$MustExist) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $volumeRoot.Length) {
        $full = $full.TrimEnd('\')
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) {
        throw "CGCE-OPS-PATH missing path"
    }
    return $full
}

function Assert-CgceTreeHasNoReparsePoints([string]$Root) {
    $all = @((Get-Item -LiteralPath $Root -Force)) +
        @(Get-ChildItem -LiteralPath $Root -Force -Recurse)
    foreach ($item in $all) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CGCE-OPS-REPARSE reparse point found"
        }
    }
}

function Get-CgceTreeInventory([string]$Root) {
    $canonical = Resolve-CgceCanonicalPath -Path $Root -MustExist $true
    $prefix = $canonical + "\"
    $records = foreach ($file in Get-ChildItem -LiteralPath $canonical -File -Force -Recurse) {
        [pscustomobject]@{
            relative_path = $file.FullName.Substring($prefix.Length).Replace('\','/')
            length = [int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return @($records | Sort-Object relative_path)
}
```

`Assert-CgceDistinctRoots` must compare canonical paths case-insensitively and
reject equality or component-boundary nesting. Call it only for paths that are
supposed to be independent; do not pass an intentional parent and child such as
`ServerRoot` and `SavedPath`. `Assert-CgceNoReparseInPath` walks every existing
component from the volume root through the target or nearest existing parent
and rejects reparse points, including a junction outside the copied tree.
`Compare-CgceInventory` must compare count, relative path, length, and SHA-256
at every index.

`New-CgceRunPaths` is pure and creates no directory. It canonicalizes its five
inputs, requires the exact active suffix `<ServerRoot>\Pal\Saved`, validates the
fixed RunId grammar, and returns the exact `paths` key set from Task 1. Every
inactive original/test quarantine and UE4SS before-image/test quarantine is a
run-id-qualified same-volume sibling. Every backup, inventory, capture, state,
genesis snapshot, and receipt is below `<RunRoot>\<run_id>`. The active marker
is `<ServerRoot>\.cgce-discovery-active.json`; the completed marker is
`<ServerRoot>\.cgce-discovery-completed-<run_id>.json`. No entry point may
re-derive an individual path independently.

Add canonicalization tests for `D:\`, a normal descendant, trailing
separators, case differences, and a UNC share root. A drive root must stay
`D:\`, never collapse to drive-relative `D:`.

`Write-CgceInventory` writes a strict object envelope with exact keys
`schema_version,kind,entries`; `Read-CgceInventory` rejects unknown fields,
non-dense entries, unsorted/duplicate paths, and invalid lengths/checksums.
Inventory files are objects, never ambiguous top-level JSON arrays.

- [ ] **Step 4: Implement verified copy and no-overwrite move**

`Copy-CgceTreeVerified` must:

1. reject existing destination;
2. reject reparse points in the source tree and both source/destination path
   component chains before copy;
3. select a unique same-volume sibling staging path beside the destination and
   invoke `%SystemRoot%\System32\robocopy.exe` against that staging path with
   `/E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ`;
4. accept only robocopy exit codes `0..7`;
5. inventory staging and exact-compare it to the original source inventory;
6. immediately before publication, revalidate every source/staging/destination
   component chain and tree, recompute source inventory, and compare original
   source, current source, and staging;
7. publish staging with `[System.IO.Directory]::Move`, which fails when the
   final destination exists;
8. after publication, recompute source and destination inventories and compare
   current source, original source, and final destination before returning the
   destination inventory.

`Move-CgceDirectoryNoOverwrite` must require source directory, absent
destination, reparse-free path components, and equal volume roots before
immediately revalidating the component chains and calling
`[System.IO.Directory]::Move`. An existing final destination must fail rather
than becoming a move container.

`Copy-CgceFileVerified` must reject a missing source or existing destination,
copy one file to a unique same-volume sibling staging path with
`[System.IO.File]::Copy(..., overwrite=false)`, compare staging length and
SHA-256, immediately revalidate source/staging/destination component chains,
then publish with `[System.IO.File]::Move` and verify the final file. Use it for
`UE4SS_ObjectDump.txt`; never copy the whole UE4SS root as capture. Staging
artifacts are preserved on failure; these helpers never delete them.

- [ ] **Step 5: Run GREEN and commit**

Run the Windows suite; expected all Files tests pass.

Commit:

```bash
git add tools/windows-discovery/modules tests/windows
git commit -m "feat: verify Windows discovery filesystem copies"
```

---

### Task 3: UE4SS inventory probe and runtime preflight

**Purpose:** exact UE4SS root에 격리 probe를 stage하고 test process만 한 번
실행할 수 있는 runtime boundary를 만든다.

**Files:**
- Create: `tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua`
- Create: `tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1`
- Create: `tests/windows/Runtime.Tests.ps1`
- Modify: `tools/windows-discovery/CgceDiscovery.Common.psm1`
- Modify: `tests/windows/Run-CgceDiscoveryTests.ps1`
- Create: `tests/integration/discovery_handoff_spec.lua`

**Interfaces:**
- Consumes: contract and filesystem modules.
- Produces: runtime functions listed in `Approved Interfaces`.
- Error codes:
  `CGCE-OPS-PROCESS-ACTIVE`, `CGCE-OPS-PORT-ACTIVE`,
  `CGCE-OPS-ARGUMENT`, `CGCE-OPS-PROBE-EXISTS`,
  `CGCE-OPS-MODS-TXT`, `CGCE-OPS-PROCESS-TIMEOUT`,
  `CGCE-OPS-CAPTURE-MISSING`, `CGCE-OPS-PROCESS-QUERY`,
  `CGCE-OPS-PORT-QUERY`, `CGCE-OPS-PROCESS-UNLISTED`,
  `CGCE-OPS-PROCESS-RECEIPT`, `CGCE-OPS-PROBE-RECEIPT`,
  `CGCE-OPS-FOREIGN-ARTIFACT`, `CGCE-OPS-MANUAL-RECOVERY`.

#### Fixed Task 3 runtime journal contract

The exact 41-key `Paths` object from Task 2 remains unchanged. Task 3 Runtime
may derive only these fixed journal/snapshot children:

```text
<run_directory>\before\
  010-mods-txt.json
  020-object-dump.json
  030-cxx-header-dump.json
  040-ue4ss-log.json
  050-probe-source.json

<probe_receipts>\
  000-probe-intent.json
  010-preserve-mods.json
  020-create-test-mods.json
  030-preserve-object-dump.json
  040-preserve-cxx-header-dump.json
  050-preserve-ue4ss-log.json
  060-stage-probe.json
  999-probe-final.json
  restore\
    000-probe-restore-intent.json
    010-quarantine-probe.json
    020-quarantine-test-mods.json
    030-restore-mods.json
    040-quarantine-object-dump.json
    050-restore-object-dump.json
    060-quarantine-cxx-header-dump.json
    070-restore-cxx-header-dump.json
    080-quarantine-ue4ss-log.json
    090-restore-ue4ss-log.json
    999-probe-restore-final.json

<process_receipts>\
  000-launch.json
  001-pid.json ... 998-pid.json
  999-result.json
```

This allowlist is scoped to Task 3 Runtime-owned snapshots and journals.
Later entry-point-owned children, including Task 5/7 fixed capture payloads
below `Paths.capture`, remain governed by those tasks. Atomic
`<target>.tmp` files may exist only during `Write-CgceJsonAtomic`. Unknown
children, stale temp files, gaps, duplicates, or checksum drift block automatic
recovery.

Every runtime JSON object has `schema_version="1.0"`, its exact key set, no
unknown/duplicate/case-variant key, UTF-8 without BOM, strict read-back, and a
no-overwrite write. Exact snapshot keys are:

```text
schema_version,kind,run_id,artifact_name,artifact_type,path,
present,length,sha256,entries
```

The five snapshots bind `MODS_TXT`, `OBJECT_DUMP`, `CXX_HEADER_DUMP`,
`UE4SS_LOG`, and `PROBE_SOURCE` in that order. File snapshots use
`length,sha256`; directory snapshots use the full sorted inventory in
`entries`; absent optional artifacts use null measurements. The probe intent
has exact keys:

```text
schema_version,kind,run_id,created_at_utc,run_directory,ue4ss_root,
paths,snapshots
```

Its `paths` object has exact keys:

```text
before_directory,probe_source,probe_staged,probe_quarantine,
mods_txt,mods_original,mods_test,
object_dump,object_dump_original,object_dump_quarantine,
cxx_header_dump,cxx_header_dump_original,cxx_header_dump_quarantine,
ue4ss_log,ue4ss_log_original,ue4ss_log_quarantine,
probe_receipts,probe_restore_receipts,probe_final_receipt
```

Each snapshot binding has exact keys
`artifact_name,snapshot_path,snapshot_sha256`. Probe and probe-restore
operation receipts have exact keys:

```text
schema_version,kind,run_id,sequence,step,operation,
source_path,destination_path,before_state,after_state,
previous_receipt_sha256,completed_at_utc
```

The named `artifact_state` schema has exact keys
`artifact_type,present,length,sha256,tree_sha256`. Every operation receipt
`before_state` and `after_state` is the named `operation_pair_state` schema
with exact keys
`source,destination`; each value is either null or one `artifact_state`.
When `source_path=null`, `source=null`; otherwise both pair members are
explicit `artifact_state` objects, including explicit absent states.
Staging sequences/steps are
`010 PRESERVE_MODS`, `020 CREATE_TEST_MODS`,
`030 PRESERVE_OBJECT_DUMP`, `040 PRESERVE_CXX_HEADER_DUMP`,
`050 PRESERVE_UE4SS_LOG`, and `060 STAGE_PROBE`; absent optional artifacts
still receive a gapless `VERIFY_ABSENT` receipt. Restore sequences/steps are
`010 QUARANTINE_PROBE`, `020 QUARANTINE_TEST_MODS`, `030 RESTORE_MODS`,
`040 QUARANTINE_OBJECT_DUMP`, `050 RESTORE_OBJECT_DUMP`,
`060 QUARANTINE_CXX_HEADER_DUMP`, `070 RESTORE_CXX_HEADER_DUMP`,
`080 QUARANTINE_UE4SS_LOG`, and `090 RESTORE_UE4SS_LOG`. Each operation
points to the preceding exact receipt checksum.

The probe final has exact keys:

```text
schema_version,kind,run_id,sequence,intent_sha256,
previous_receipt_sha256,mods_before_sha256,mods_after_sha256,
staged_path,paths,operation_receipts,completed_at_utc
```

The restore intent has exact keys:

```text
schema_version,kind,run_id,sequence,created_at_utc,
stage_intent_sha256,stage_final_sha256,
stage_chain_last_sequence,stage_chain_last_sha256,paths,plans
```

Each plan has exact keys
`artifact_name,selected_case,before_present,active_state,original_state,
quarantine_state`. The restore final has exact keys:

```text
schema_version,kind,run_id,sequence,restore_intent_sha256,
previous_receipt_sha256,paths,operation_receipts,restored_states,
completed_at_utc
```

Each receipt binding is exactly `sequence,path,sha256`; each restored-state
binding is exactly `artifact_name,state`. Restoration validates the longest
valid staging/restore prefix and accepts an unreceipted completed operation
only when the intent-bound source/destination states prove that exact next
step. It never backfills the staging journal, overwrites, deletes, or crosses a
volume; ambiguity returns `CGCE-OPS-MANUAL-RECOVERY`.

The restore intent freezes the selected case and entry states before step 010.
The fixed paths are:

| Seq | Source | Destination | Kind |
|---:|---|---|---|
| 010 | `probe_staged` | `probe_quarantine` | directory |
| 020 | `mods_txt` | `mods_test` | file |
| 030 | `mods_original` | `mods_txt` | file |
| 040 | `object_dump` | `object_dump_quarantine` | file |
| 050 | `object_dump_original` | `object_dump` | file |
| 060 | `cxx_header_dump` | `cxx_header_dump_quarantine` | directory |
| 070 | `cxx_header_dump_original` | `cxx_header_dump` | directory |
| 080 | `ue4ss_log` | `ue4ss_log_quarantine` | file |
| 090 | `ue4ss_log_original` | `ue4ss_log` | file |

For a move, the before pair is exact present source plus absent destination and
the after pair is absent source plus the same exact destination.
`VERIFY_ABSENT` binds absent artifact states for both pair members before/after;
`VERIFY_RESTORED` binds the identical case-specific pair before/after.

The normative case-to-step matrix is:

```text
PROBE_NOT_STAGED:
  010 VERIFY_ABSENT (-,-) -> (-,-)
PROBE_ACTIVE:
  010 MOVE_DIRECTORY (T,-) -> (-,T)
PROBE_ALREADY_QUARANTINED:
  010 VERIFY_RESTORED (-,T) -> (-,T)

ORIGINAL_UNCHANGED:
  020 VERIFY_RESTORED (A,Q)=(B,-)
  030 VERIFY_RESTORED (O,A)=(-,B)
ORIGINAL_PRESERVED_NO_TEST:
  020 VERIFY_ABSENT (A,Q)=(-,-)
  030 MOVE_FILE O(B)->A
TEST_ACTIVE_AND_ORIGINAL_PRESERVED:
  020 MOVE_FILE A(T)->Q
  030 MOVE_FILE O(B)->A
TEST_QUARANTINED_AND_ORIGINAL_PRESERVED:
  020 VERIFY_RESTORED (A,Q)=(-,T)
  030 MOVE_FILE O(B)->A
ORIGINAL_ALREADY_RESTORED:
  020 VERIFY_RESTORED (A,Q)=(B,<intent-bound - or T>)
  030 VERIFY_RESTORED (O,A)=(-,B)

BEFORE_ABSENT_NO_TEST:
  quarantine VERIFY_ABSENT; restore VERIFY_ABSENT
BEFORE_ABSENT_TEST_ACTIVE:
  quarantine MOVE A(T)->Q; restore VERIFY_ABSENT
BEFORE_ABSENT_TEST_QUARANTINED:
  quarantine VERIFY_RESTORED (A,Q)=(-,T); restore VERIFY_ABSENT
BEFORE_PRESENT_ORIGINAL_PRESERVED_NO_TEST:
  quarantine VERIFY_ABSENT; restore MOVE O(B)->A
BEFORE_PRESENT_TEST_ACTIVE_AND_ORIGINAL_PRESERVED:
  quarantine MOVE A(T)->Q; restore MOVE O(B)->A
BEFORE_PRESENT_TEST_QUARANTINED_AND_ORIGINAL_PRESERVED:
  quarantine VERIFY_RESTORED (A,Q)=(-,T); restore MOVE O(B)->A
BEFORE_PRESENT_ALREADY_RESTORED:
  quarantine VERIFY_RESTORED (A,Q)=(B,<intent-bound - or T>)
  restore VERIFY_RESTORED (O,A)=(-,B)
```

The seven output cases apply independently to object dump steps 040/050, CXX
header steps 060/070, and log steps 080/090 with the fixed file/directory move
kind. For the next missing receipt only, live state must equal either the
frozen exact before state (perform once, verify, receipt) or exact after state
(operation completed before receipt; verify and receipt). Any other state is
manual recovery without mutation.

`000-launch.json` is the immutable pre-launch intent, not a post-launch PID
receipt. It has exact keys:

```text
schema_version,kind,run_id,sequence,created_at_utc,
executable_path,executable_sha256,working_directory,
allowed_executable_path_count,allowed_executable_paths_sha256,
argument_count,arguments_sha256,timeout_seconds,previous_receipt_sha256
```

It is written, strictly read back, and checksum-verified before
`Start-Process`; any pre-existing process-journal child is the one-launch
replay barrier. Root/descendant identities are separate gapless
`001..998-pid.json` files with exact keys:

```text
schema_version,kind,run_id,sequence,pid,parent_pid,executable_path,
creation_time_utc,creation_time_filetime_utc,observed_at_utc,
previous_receipt_sha256
```

PID identity is exact PID + canonical executable path + UTC creation
`FileTime`. `999-result.json` has exact keys:

```text
schema_version,kind,run_id,sequence,launch_receipt_sha256,
previous_receipt_sha256,started_at_utc,exit_at_utc,exit_code,
observed_processes,pid_receipts
```

Each observed-process item is exactly
`sequence,pid,parent_pid,executable_path,creation_time_utc,
creation_time_filetime_utc`; argument plaintext is never persisted. Argument
and allowlist digests frame the ordered UTF-8 strings with domains
`CGCE-ARGS-1\0` and `CGCE-PATHS-1\0`, a big-endian UInt32 count, then each
big-endian UInt32 byte length and bytes. Directory `tree_sha256` frames the
sorted inventory with `CGCE-TREE-1\0`, count, each path length/path, UInt64
file length, and raw 32-byte file checksum.

Receipt-aware `Assert-CgceNoServerActivity` recomputes the exact canonical
allowlist count/framed digest and requires it to match `000-launch.json`;
mismatch is `CGCE-OPS-PROCESS-RECEIPT`. Preflight claims only exact
allowlisted-image blocking, still-live durable PID identity blocking, and
configured endpoint blocking. During one launched run, ancestry polling
enforces the allowlist for every descendant actually observed from the known
root. It does not claim kernel-enforced containment or complete history for an
extremely short-lived descendant between polling samples.

- [ ] **Step 1: Write failing runtime tests**

```powershell
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1" -Force
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Files.psm1" -Force

Invoke-CgceTest "rejects public lobby and secret arguments" {
    Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
        Assert-CgceServerArguments -Arguments @("-publiclobby")
    }
    Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
        Assert-CgceServerArguments -Arguments @("-AdminPassword=not-a-real-secret")
    }
}

Invoke-CgceTest "enables one exact mods line" {
    $base = Join-Path $env:TEMP ("cgce-runtime-" + [guid]::NewGuid().ToString("N"))
    $serverRoot = Join-Path $base "server"
    $saved = Join-Path $serverRoot "Pal\Saved"
    $root = Join-Path $serverRoot "Pal\Binaries\Win64"
    New-Item -ItemType Directory -Path $saved -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "Mods") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root "UE4SS.dll") -Value "synthetic" -NoNewline
    Set-Content -LiteralPath (Join-Path $root "Mods\mods.txt") -Value "BPModLoaderMod : 1"
    $probe = Join-Path $PSScriptRoot "..\..\tools\windows-discovery\probe\CGCEDiscoveryInventory"
    $runRoot = Join-Path $base "run"
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $runId = "r-0123456789abcdef0123456789abcdef"
    $paths = New-CgceRunPaths `
        -ServerRoot $serverRoot -SavedPath $saved -Ue4ssRoot $root `
        -RunRoot $runRoot -RunId $runId
    New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
    New-Item -ItemType Directory -Path $paths.probe_receipts | Out-Null
    $receipt = Enable-CgceInventoryProbe `
        -Ue4ssRoot $root -ProbeSource $probe -RunDirectory $paths.run_directory `
        -RunId $runId -Paths $paths
    $lines = @(Get-Content (Join-Path $root "Mods\mods.txt"))
    Assert-CgceEqual 1 $lines.Count
    Assert-CgceEqual "CGCEDiscoveryInventory : 1" $lines[0]
}
```

- [ ] **Step 2: Add a static Lua test that forbids game mutation surfaces**

```lua
local path = "tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a")
file:close()

assert(source:find("DumpAllObjects()", 1, true))
assert(source:find("GenerateSDK()", 1, true))
for _, forbidden in ipairs({
    "StaticFindObject", "FindAllOf", "RegisterHook", "ExecuteInGameThread",
    "SetPropertyValue", "ProcessConsoleExec", "TArray", "resize", "append",
}) do
    assert(not source:find(forbidden, 1, true), forbidden)
end
```

- [ ] **Step 3: Run RED**

Run:

```bash
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Expected: missing probe source.

Run the Windows suite. Expected: missing runtime module.

- [ ] **Step 4: Implement the isolated probe**

```lua
local function run_dumper(name, fn)
    local ok = pcall(fn)
    if not ok then
        print("CGCE_INVENTORY_BLOCKED " .. name)
        return false
    end
    print("CGCE_INVENTORY_COMPLETE " .. name)
    return true
end

local objects_ok = run_dumper("OBJECTS", DumpAllObjects)
local sdk_ok = run_dumper("CXX_HEADERS", GenerateSDK)

if objects_ok and sdk_ok then
    print("CGCE_INVENTORY_COMPLETE ALL")
else
    print("CGCE_INVENTORY_BLOCKED ALL")
end
```

This file must contain no `require` of CGCE production modules and no candidate
lookup, property access, hook, or game function call.

- [ ] **Step 5: Implement runtime checks and reversible probe staging**

`Enable-CgceInventoryProbe` must:

1. require `<Ue4ssRoot>\UE4SS.dll`, `<Ue4ssRoot>\Mods`, and
   `<Ue4ssRoot>\Mods\mods.txt`;
2. reject an existing `CGCEDiscoveryInventory` directory or duplicate mods line;
3. atomically create the no-overwrite `Paths.probe_intent` that binds RunId,
   every source/destination path, and before-image checksum/inventory;
4. move `mods.txt` to the same-volume sibling
   `mods.txt.cgce-original-<run_id>`, then create a fresh `mods.txt` whose only
   non-comment line is `CGCEDiscoveryInventory : 1`; write it as UTF-8 without
   BOM and with one final CRLF using `System.Text.UTF8Encoding($false)`;
5. move any existing `UE4SS_ObjectDump.txt`, `CXXHeaderDump`, and `UE4SS.log`
   to distinct same-volume sibling paths suffixed
   `.cgce-original-<run_id>`;
6. verified-copy the probe directory;
7. byte-read and verify the fresh mods file has exactly that one line and no
   other enabled mod or BOM;
8. after every move/create/copy, atomically write a numbered no-overwrite
   operation receipt chained to the previous receipt checksum;
9. write the sole final receipt at `Paths.probe_receipt`, containing the
   pre/post mods checksums, staged path, and every
   before-image/output/quarantine path; return only its exact canonical path and
   file checksum to the caller. Copy only before-image checksums and
   inventories—not their bytes—into `<RunDirectory>\before`. The caller never
   writes the final receipt a second time.

`Restore-CgceInventoryProbe` moves the staged probe and newly generated dumper
outputs/`UE4SS.log` to distinct same-volume paths suffixed
`.cgce-test-<run_id>`, then restores the exact before-image `mods.txt` and any
pre-existing dumper outputs/`UE4SS.log` with no-overwrite moves. It is
idempotent through the probe intent and chained operation receipts; ambiguous
source/destination pairs return `CGCE-OPS-MANUAL-RECOVERY`. No lifecycle move
crosses a volume boundary.

The fixed `Paths` object, intent, and per-operation receipts—not the final
receipt alone—are the recovery authority. Add injected-crash tests before and
after every probe-stage filesystem operation. From phase `CLONE_ACTIVE`, each
fixture must either restore every UE4SS before-image exactly or block manual
recovery without overwriting anything.

`Assert-CgceServerArguments` rejects case-insensitive exact/prefix forms of:

```text
-publiclobby
-AdminPassword
-ServerPassword
-RCONPassword
-RESTAPIKey
```

It also accepts only non-empty tokens matching
`^[-A-Za-z0-9_=.:/\\]+$`. Spaces, quotes, control characters, shell
metacharacters, and response-file syntax are blocked so Windows native
command-line joining cannot reinterpret an argument.

`Assert-CgceNoServerActivity` queries `Win32_Process.ExecutablePath` and
requires no process matching any exact control-bound executable path, no PID
plus creation-time identity from an optional process receipt root that is still
alive, and no established or listening TCP/UDP endpoint for every configured
port. Reused numeric PIDs do not match unless executable path and creation time
also match. The control contract defines `server_process_paths` as the
operator-attested exhaustive executable-image set for launcher and all possible
server-owned descendants. Any observed descendant outside that set is a
blocking contract violation. It does not rely on one hard-coded process name.
Missing/incomplete path attestation, CIM access, `Get-NetTCPConnection`, or
`Get-NetUDPEndpoint` is a blocking preflight error.

- [ ] **Step 6: Run GREEN and commit**

Run the focused Lua test and Windows suite. Expected: all pass.

Commit:

```bash
git add tools/windows-discovery tests
git commit -m "feat: add isolated Windows inventory probe"
```

---

### Task 4: Prepare lifecycle entry point

**Purpose:** verified backup 없이는 original을 이동하지 않고, original
deactivation과 clone activation을 state-bound operation으로 만든다.

**Files:**
- Create: `tools/windows-discovery/Prepare-CgceDiscovery.ps1`
- Create: `tests/windows/Lifecycle.Tests.ps1`
- Modify: `tools/windows-discovery/CgceDiscovery.Common.psm1`
- Modify: `tests/windows/Run-CgceDiscoveryTests.ps1`

**Interfaces:**
- Consumes: exact control evidence, bundle checksum, server/Saved/UE4SS paths.
- Produces: `run-state.json` at phase `PROBE_STAGED`, original/backup/clone
  inventories, inactive original, active clone, probe receipt.
- Error codes:
  `CGCE-OPS-DISK`, `CGCE-OPS-BACKUP`, `CGCE-OPS-CLONE`,
  `CGCE-OPS-STATE-EXISTS`, `CGCE-OPS-BLOCKED`.

- [ ] **Step 1: Write a failing synthetic prepare test**

```powershell
Invoke-CgceTest "prepare preserves original and activates an equal clone" {
    $fixture = New-CgceSyntheticFixture
    & "$PSScriptRoot\..\..\tools\windows-discovery\Prepare-CgceDiscovery.ps1" `
        -ServerRoot $fixture.ServerRoot `
        -SavedPath $fixture.SavedPath `
        -Ue4ssRoot $fixture.Ue4ssRoot `
        -ServerExecutable $fixture.ServerExecutable `
        -RunRoot $fixture.RunRoot `
        -RunId $fixture.RunId `
        -HandoffRoot $fixture.HandoffRoot `
        -SourceManifestPath $fixture.SourceManifestPath `
        -ControlEvidencePath $fixture.ControlPath `
        -ControlEvidenceSha256 $fixture.ControlSha `
        -BundleSha256 $fixture.BundleSha
    $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    Assert-CgceEqual "PROBE_STAGED" $state.phase
    Assert-CgceEqual $true (Test-Path $state.paths.inactive_original)
    Assert-CgceEqual $true (Test-Path $fixture.SavedPath)
}
```

`New-CgceSyntheticFixture` must create only temporary dummy files, copy
`%SystemRoot%\System32\cmd.exe` into the synthetic ServerRoot, and bind that
copied executable in control evidence. It must not contain a real save or
credential.

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: prepare script missing.

- [ ] **Step 3: Implement prepare with phase checkpoints**

The entry point order is exact:

```powershell
$validated = Assert-CgceControlEvidence `
    -EvidencePath $ControlEvidencePath `
    -ExpectedFileChecksum $ControlEvidenceSha256 `
    -ExpectedBundleChecksum $BundleSha256 `
    -NowUtc ([DateTime]::UtcNow)

Assert-CgceHandoffSource -HandoffRoot $HandoffRoot -ManifestPath $SourceManifestPath
if ($validated.run_id -cne $RunId) {
    throw "CGCE-OPS-ID control/run ID mismatch"
}
Assert-CgceEqualCanonicalPath -Expected $validated.server_root -Actual $ServerRoot
Assert-CgceEqualCanonicalPath -Expected $validated.ue4ss_root -Actual $Ue4ssRoot
Assert-CgceEqualCanonicalPath -Expected $validated.palserver_executable -Actual $ServerExecutable
$paths = New-CgceRunPaths `
    -ServerRoot $ServerRoot -SavedPath $SavedPath -Ue4ssRoot $Ue4ssRoot `
    -RunRoot $RunRoot -RunId $RunId
$statePath = $paths.state
$runDirectory = $paths.run_directory
$inactiveOriginal = $paths.inactive_original
$quarantinedClone = $paths.quarantined_clone
$backupSaved = $paths.backup_saved
$probeSource = Join-Path $HandoffRoot `
    "tools\windows-discovery\probe\CGCEDiscoveryInventory"
$lock = Enter-CgceExclusiveLock -ServerRoot $ServerRoot -RunId $RunId
if ((Get-CgceSha256 -Path (Join-Path $Ue4ssRoot "UE4SS.dll")) -ne
        $validated.ue4ss_dll_sha256) {
    throw "CGCE-OPS-CHECKSUM UE4SS DLL drift"
}
Assert-CgceNoServerActivity `
    -ExecutablePaths @($validated.server_process_paths) `
    -Ports @($validated.listener_ports)
Assert-CgceNoForeignRunArtifacts `
    -ServerRoot $ServerRoot -Ue4ssRoot $Ue4ssRoot -RunId $RunId
Assert-CgceDistinctRoots -Paths @($ServerRoot, $RunRoot)
Assert-CgcePathContainedBy -Path $SavedPath -Root $ServerRoot
Assert-CgcePathContainedBy -Path $Ue4ssRoot -Root $ServerRoot
Assert-CgceDistinctRoots -Paths @($SavedPath, $inactiveOriginal, $backupSaved, $quarantinedClone)
Assert-CgceNoReparseInPath -Path $RunRoot
Assert-CgceNoReparseInPath -Path $Ue4ssRoot
Assert-CgceTreeHasNoReparsePoints -Root $SavedPath

Copy-CgceFileVerified `
    -Source $ControlEvidencePath -Destination $paths.control_evidence | Out-Null
if ((Get-CgceSha256 -Path $paths.control_evidence) -ne $ControlEvidenceSha256) {
    throw "CGCE-OPS-CHECKSUM copied control evidence drift"
}
$original = @(Get-CgceTreeInventory -Root $SavedPath)
$originalChecksum = Write-CgceInventory `
    -Entries $original -Path $paths.original_inventory -Kind "original"
$state = New-CgceRunState -RunId $RunId -MaintenanceId $validated.maintenance_id -Paths $paths
$state.bundle_checksum = $BundleSha256
$state.control_evidence_checksum = $ControlEvidenceSha256
$state.palserver_executable = $ServerExecutable
$state.palserver_executable_checksum = Get-CgceSha256 -Path $ServerExecutable
$state.server_process_paths = @($validated.server_process_paths)
$state.ue4ss_version = $validated.ue4ss_version
$state.ue4ss_dll_checksum = $validated.ue4ss_dll_sha256
$state.listener_ports = @($validated.listener_ports)
$state.inventory_checksums.original = $originalChecksum
Write-CgceJsonAtomic -Value $state -Path $paths.genesis_state
$null = Copy-CgceFileVerified -Source $paths.genesis_state -Destination $statePath
$genesisChecksum = Get-CgceSha256 -Path $paths.genesis_state
Write-CgceActiveRunMarker `
    -State $state -GenesisStateChecksum $genesisChecksum `
    -Path $state.paths.active_run_marker

$backup = Copy-CgceTreeVerified -Source $SavedPath -Destination $backupSaved
Compare-CgceInventory -Expected $original -Actual $backup
$state.inventory_checksums.backup = Write-CgceInventory `
    -Entries $backup -Path $state.paths.backup_inventory -Kind "backup"
$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "CREATED" -NextPhase "BACKUP_VERIFIED"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "CREATED"

Move-CgceDirectoryNoOverwrite -Source $SavedPath -Destination $inactiveOriginal
$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "BACKUP_VERIFIED" -NextPhase "ORIGINAL_DEACTIVATED"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "BACKUP_VERIFIED"

$clone = Copy-CgceTreeVerified -Source $backupSaved -Destination $SavedPath
Compare-CgceInventory -Expected $original -Actual $clone
$state.inventory_checksums.clone = Write-CgceInventory `
    -Entries $clone -Path $state.paths.clone_inventory -Kind "clone"
$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "ORIGINAL_DEACTIVATED" -NextPhase "CLONE_ACTIVE"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "ORIGINAL_DEACTIVATED"

$probeResult = Enable-CgceInventoryProbe `
    -Ue4ssRoot $Ue4ssRoot -ProbeSource $probeSource -RunDirectory $runDirectory `
    -RunId $RunId -Paths $state.paths
Assert-CgceEqualCanonicalPath `
    -Expected $state.paths.probe_receipt -Actual $probeResult.path
if ((Get-CgceSha256 -Path $state.paths.probe_receipt) -ne $probeResult.checksum) {
    throw "CGCE-OPS-CHECKSUM probe final receipt drift"
}
$state.probe_receipt_checksum = $probeResult.checksum
$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "CLONE_ACTIVE" -NextPhase "PROBE_STAGED"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "CLONE_ACTIVE"
```

Everything after lock acquisition runs inside `try/finally` and disposes the
lock handle in `finally`; no entry point continues when lock acquisition
fails.

Use only `New-CgceRunPaths`; do not accept any lifecycle destination as an
unconstrained path or re-derive one locally. Create the no-overwrite run
directory and its fixed subdirectories, copy the validated control evidence,
and write the original inventory first. Then write immutable
`run-state.genesis.json` at `CREATED`, verified-copy the exact bytes to
`run-state.json`, and bind the marker to the genesis checksum.
Create `<ServerRoot>\.cgce-discovery-active.json` immediately afterward with
no-overwrite semantics and bind it to RunId, RunRoot, and the immutable genesis
state checksum. Later state compare-and-swap replacements do not change that
binding.
Nothing before state/marker creation changes a production path. A foreign
active marker, any `Saved.cgce-original-*`, any UE4SS
`.cgce-original-*`, or an existing staged inventory probe blocks a fresh run;
completed `.cgce-test-*` quarantines and completed marker history may remain.
Check free space separately on the backup and server volumes for the backup and
clone copies.

Write every inventory before its phase transition. Persist each transition
immediately with the compare-and-swap state writer. On error, atomically set
`outcome=BLOCKED`, append one stable error object, leave all trees in place,
print the blocked terminal line, and exit non-zero.

- [ ] **Step 4: Add failure tests**

Prove prepare rejects process/listener activity, CLI/control path mismatch,
actual control-file checksum mismatch, handoff source-manifest drift,
PalServer/UE4SS DLL checksum drift, unsupported UE4SS version, existing run
state, expired evidence, invalid containment, unintended root overlap, reparse
point, foreign active/incomplete-run markers, insufficient free space on either
volume, copy drift, and existing probe. Prove later state revisions keep
validating against the immutable genesis checksum while genesis or marker drift
blocks. For every failure before
`BACKUP_VERIFIED`, assert active Saved bytes remain unchanged.

- [ ] **Step 5: Run GREEN and commit**

Run the Windows suite. Expected: prepare and failure tests pass.

Commit:

```bash
git add tools/windows-discovery tests/windows
git commit -m "feat: prepare verified Windows discovery clone"
```

---

### Task 5: Invoke and capture entry point

**Purpose:** prepared clone에서 exact child process를 한 번 실행하고, process가
종료된 뒤에만 dump output을 run capture로 복사한다.

**Files:**
- Create: `tools/windows-discovery/Invoke-CgceDiscovery.ps1`
- Create: `tests/windows/fixtures/FakePalServer.cmd`
- Modify: `tests/windows/Runtime.Tests.ps1`
- Modify: `tests/windows/Lifecycle.Tests.ps1`

**Interfaces:**
- Consumes: `PROBE_STAGED` state and a JSON dense string array of arguments.
- Produces: child PID/create/exit receipt, object/header capture inventory,
  phase `CAPTURED`.
- Error codes: `CGCE-OPS-PROCESS-EXIT`, `CGCE-OPS-CAPTURE-MISSING`,
  `CGCE-OPS-PHASE`, `CGCE-OPS-CHECKSUM`.

- [ ] **Step 1: Write failing argument/process/capture tests**

```powershell
Invoke-CgceTest "invoke captures outputs only after child exit" {
    $fixture = New-CgcePreparedFixture
    & "$PSScriptRoot\..\..\tools\windows-discovery\Invoke-CgceDiscovery.ps1" `
        -RunRoot $fixture.RunRoot `
        -RunId $fixture.RunId `
        -ServerExecutable $fixture.ServerExecutable `
        -ArgumentsPath $fixture.ArgumentsPath `
        -TimeoutSeconds 30
    $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    Assert-CgceEqual "CAPTURED" $state.phase
    Assert-CgceEqual $true (Test-Path (Join-Path $fixture.RunDirectory "capture\UE4SS_ObjectDump.txt"))
}
```

The fake server fixture receives a synthetic UE4SS root, writes
`UE4SS_ObjectDump.txt`, `CXXHeaderDump\Synthetic.hpp`, and a fresh `UE4SS.log`
containing `CGCE_INVENTORY_COMPLETE ALL`, then exits `0`.

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: invoke script missing.

- [ ] **Step 3: Implement exact child invocation**

```powershell
$provisional = Read-CgceRunState -RunRoot $RunRoot -RunId $RunId
$lock = Enter-CgceExclusiveLock -ServerRoot $provisional.paths.server_root -RunId $RunId
$state = Read-CgceRunState -RunRoot $RunRoot -RunId $RunId
$statePath = $state.paths.state
if ($state.phase -ne "PROBE_STAGED" -or $state.outcome -ne "ACTIVE") {
    throw "CGCE-OPS-PHASE invoke requires PROBE_STAGED"
}
Assert-CgceRunMarker -State $state

$arguments = Read-CgceJsonStringArray -Path $ArgumentsPath
Assert-CgceServerArguments -Arguments $arguments
Assert-CgceEqualCanonicalPath -Expected $state.palserver_executable -Actual $ServerExecutable
if ((Get-CgceSha256 -Path $ServerExecutable) -ne $state.palserver_executable_checksum) {
    throw "CGCE-OPS-CHECKSUM PalServer executable drift"
}
if ((Get-CgceSha256 -Path $state.paths.ue4ss_dll) -ne $state.ue4ss_dll_checksum) {
    throw "CGCE-OPS-CHECKSUM UE4SS DLL drift"
}
Assert-CgceControlEvidence `
    -EvidencePath $state.paths.control_evidence `
    -ExpectedFileChecksum $state.control_evidence_checksum `
    -ExpectedBundleChecksum $state.bundle_checksum `
    -NowUtc ([DateTime]::UtcNow) | Out-Null
Assert-CgceNoServerActivity `
    -ExecutablePaths @($state.server_process_paths) `
    -Ports @($state.listener_ports) `
    -ReceiptRoot $state.paths.process_receipts

$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "PROBE_STAGED" -NextPhase "RUNNING"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "PROBE_STAGED"
$processRun = Invoke-CgceChildProcess `
    -Executable $ServerExecutable `
    -ExpectedExecutableChecksum $state.palserver_executable_checksum `
    -AllowedExecutablePaths @($state.server_process_paths) `
    -Arguments $arguments `
    -ReceiptRoot $state.paths.process_receipts `
    -TimeoutSeconds $TimeoutSeconds

if ($processRun.result.exit_code -ne 0) {
    throw "CGCE-OPS-PROCESS-EXIT non-zero child exit"
}
Assert-CgceNoServerActivity `
    -ExecutablePaths @($state.server_process_paths) `
    -Ports @($state.listener_ports) `
    -ReceiptRoot $state.paths.process_receipts
if (-not (Test-Path -LiteralPath $state.paths.object_dump -PathType Leaf)) {
    throw "CGCE-OPS-CAPTURE-MISSING object dump"
}
if (-not (Test-Path -LiteralPath $state.paths.cxx_header_dump -PathType Container)) {
    throw "CGCE-OPS-CAPTURE-MISSING CXX header dump"
}
if (-not (Select-String -LiteralPath $state.paths.ue4ss_log `
        -SimpleMatch "CGCE_INVENTORY_COMPLETE ALL" -Quiet)) {
    throw "CGCE-OPS-CAPTURE-MISSING completion marker"
}

$null = Copy-CgceFileVerified `
    -Source $state.paths.object_dump `
    -Destination (Join-Path $state.paths.capture "UE4SS_ObjectDump.txt")
$null = Copy-CgceTreeVerified `
    -Source $state.paths.cxx_header_dump `
    -Destination (Join-Path $state.paths.capture "CXXHeaderDump")
$captureInventory = @(Get-CgceTreeInventory -Root $state.paths.capture)
$state.capture_inventory_checksum = Write-CgceInventory `
    -Entries $captureInventory -Path $state.paths.capture_inventory -Kind "capture"
$state.process_launch_receipt_checksum = $processRun.launch_receipt_checksum
$state.process_result_receipt_checksum = $processRun.result_receipt_checksum
if ((Get-CgceSha256 -Path $state.paths.process_launch_receipt) -ne
        $state.process_launch_receipt_checksum -or
    (Get-CgceSha256 -Path $state.paths.process_result_receipt) -ne
        $state.process_result_receipt_checksum) {
    throw "CGCE-OPS-CHECKSUM process receipt drift"
}
$state = Set-CgceRunPhase `
    -State $state -ExpectedPhase "RUNNING" -NextPhase "CAPTURED"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "RUNNING"
```

As in prepare, all work after lock acquisition is inside `try/finally`; the
state is re-read under the lock before checking phase or paths.

`Invoke-CgceChildProcess` re-hashes the executable against
`ExpectedExecutableChecksum` immediately before launch, sets the working
directory to the executable's parent, and writes the immutable no-overwrite
pre-launch intent at `process_launch_receipt` before
`Start-Process -PassThru`. It never replaces that file with PID data.
Immediately after launch it writes the root identity to `001-pid.json`; each
newly observed descendant gets the next gapless chained no-overwrite
PID/path/creation-time receipt through `998-pid.json`. Before launch it requires
`Executable` to be an exact member of `AllowedExecutablePaths`; during tracking
it canonicalizes each descendant image and blocks before success if any image
is absent from that same bound allowlist. The final
`process_result_receipt` records exit UTC/code and the full observed PID set.
During the bounded wait it recursively tracks descendants through
`Win32_Process.ParentProcessId`; success requires the root and every observed
descendant to exit, followed by the process/listener check shown above.

The state reaches `RUNNING` and the immutable launch intent exists before
launch, so a crash can never replay `Start-Process`. Preflight blocks exact
attested executable images, durable PID identities, and configured endpoints;
it does not claim to discover an arbitrary unlisted descendant before launch.
During normal ancestry polling, discovery of an observed unlisted descendant
immediately blocks the run and proves that the completeness attestation was
false. Extremely short-lived descendants that start and exit between polling
samples are outside the bounded observation claim. Restore remains blocked
until every allowlisted process, durably receipted PID identity, and configured
listener is inactive. The helper never starts a replacement process. On timeout
it throws a stable error; the entry point marks the run blocked and instructs
the operator to stop the child with the normal server shutdown procedure. It
does not restore while any tracked process or listener remains alive.

- [ ] **Step 4: Prove blocked behavior**

Add tests for argument JSON that is not a dense string array, public/secret
arguments, executable path/checksum drift, child non-zero exit, missing dumps,
missing completion marker, timeout, and phase replay. Assert capture contains
only the exact object file/header tree and no test changes the inactive
original. Add a child-spawns-grandchild fixture, a still-listening descendant
fixture, and argument cases with spaces/quotes/metacharacters to prove the
process and quoting boundaries. Inject crashes after `RUNNING`, after launch
intent, after process creation, after each PID receipt, and before result
receipt; prove Invoke never launches twice and Restore blocks until all exact
process paths, durable PIDs, and ports are inactive. Also prove incomplete
control path attestation and an observed unlisted descendant block the run.

- [ ] **Step 5: Run GREEN and commit**

Run the Windows suite and focused Lua probe test; expected all pass.

Commit:

```bash
git add tools/windows-discovery tests
git commit -m "feat: invoke and capture Windows discovery inventory"
```

---

### Task 6: Restore and crash-recovery entry point

**Purpose:** capture 성공 여부와 control-evidence 만료 여부에 관계없이
PalServer가 멈춘 뒤 original을 active path로 복원한다.

**Files:**
- Create: `tools/windows-discovery/Restore-CgceProduction.ps1`
- Modify: `tests/windows/Lifecycle.Tests.ps1`
- Modify: `tools/windows-discovery/modules/CgceDiscovery.Files.psm1`

**Interfaces:**
- Consumes: phase `CREATED` through `RESTORED`, including
  `outcome=BLOCKED`; `RESTORING` is explicitly resumable.
- Produces: quarantined test clone/probe, exact restored original inventory,
  phase `RESTORED`; preserves `BLOCKED` outcome when the run failed.
- Error code: `CGCE-OPS-MANUAL-RECOVERY`.

- [ ] **Step 1: Write failing successful and blocked restore tests**

```powershell
Invoke-CgceTest "restore returns exact original and keeps test clone" {
    $fixture = New-CgceCapturedFixture
    & "$PSScriptRoot\..\..\tools\windows-discovery\Restore-CgceProduction.ps1" `
        -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    Assert-CgceEqual "RESTORED" $state.phase
    Assert-CgceEqual $true (Test-Path $fixture.SavedPath)
    Assert-CgceEqual $true (Test-Path $state.paths.quarantined_clone)
    Compare-CgceInventory -Expected $fixture.OriginalInventory -Actual @(Get-CgceTreeInventory $fixture.SavedPath)
}
```

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: restore script missing.

- [ ] **Step 3: Implement the no-overwrite recovery matrix**

Exact cases:

```text
unchanged active original + no inactive original:
  select as a fresh case for CREATED/BACKUP_VERIFIED only when no restore intent
  exists and active inventory equals original;
  after an intent exists, accept the same layout only when that exact intent
  selected UNCHANGED_ORIGINAL and all existing receipts form its valid prefix;
  preserve any partial/complete backup without deleting it.

active clone + inactive original:
  move active clone to its fixed same-volume quarantine sibling;
  move inactive original to active Saved;
  verify restored inventory.

no active Saved + inactive original:
  move inactive original to active Saved;
  verify restored inventory.

already-restored active original + no inactive original:
  accept when active inventory equals original and the bound intent/receipt
  journal either selected UNCHANGED_ORIGINAL or proves the original restore
  move completed; otherwise block manual recovery.

any active Saved + inactive original after an unrelated quarantine target exists:
  never overwrite; block manual recovery.
```

Implementation skeleton:

```powershell
$provisional = Read-CgceRunState -RunRoot $RunRoot -RunId $RunId
$lock = Enter-CgceExclusiveLock -ServerRoot $provisional.paths.server_root -RunId $RunId
$state = Read-CgceRunState -RunRoot $RunRoot -RunId $RunId
$statePath = $state.paths.state
$activeSaved = $state.paths.active_saved
$inactiveOriginal = $state.paths.inactive_original
$quarantinedClone = $state.paths.quarantined_clone
Assert-CgceRunMarker -State $state -AllowCompleted
$original = Read-CgceInventory `
    -Path $state.paths.original_inventory -ExpectedKind "original"
if ((Get-CgceSha256 -Path $state.paths.original_inventory) -ne
        $state.inventory_checksums.original) {
    throw "CGCE-OPS-CHECKSUM original inventory drift"
}
Assert-CgceNoServerActivity `
    -ExecutablePaths @($state.server_process_paths) `
    -Ports @($state.listener_ports) `
    -ReceiptRoot $state.paths.process_receipts

if ($state.phase -eq "RESTORED") {
    Assert-CgceRestoredState -State $state
    Complete-CgceRunMarker -State $state
    return
}

$intent = Read-CgceRecoveryIntentIfPresent `
    -ReceiptRoot $state.paths.restore_receipts
if ($null -eq $intent) {
    if ($state.phase -eq "RESTORING") {
        throw "CGCE-OPS-MANUAL-RECOVERY RESTORING without intent"
    }
    $matrix = Assert-CgceRecoveryMatrix -State $state
    $intent = Write-CgceRecoveryIntent `
        -State $state -Matrix $matrix `
        -ReceiptRoot $state.paths.restore_receipts
    $sourcePhase = $state.phase
    $state.phase = "RESTORING"
    Write-CgceRunState `
        -State $state -StatePath $statePath -ExpectedPhase $sourcePhase
} else {
    Assert-CgceRecoveryIntent -State $state -Intent $intent
    if ($state.phase -ne "RESTORING") {
        if ($state.phase -ne $intent.source_phase) {
            throw "CGCE-OPS-MANUAL-RECOVERY intent/source phase mismatch"
        }
        Assert-CgceNoRestoreOperationReceipt `
            -ReceiptRoot $state.paths.restore_receipts
        $sourcePhase = $state.phase
        $state.phase = "RESTORING"
        Write-CgceRunState `
            -State $state -StatePath $statePath -ExpectedPhase $sourcePhase
    }
    $matrix = Assert-CgceRecoveryMatrix -State $state -Intent $intent
}

switch ($matrix.case) {
    "UNCHANGED_ORIGINAL" {
        # Verify only; do not move active Saved.
    }
    "CLONE_AND_INACTIVE_ORIGINAL" {
        Invoke-CgceJournaledMove -Step "010-quarantine-clone" `
            -Source $activeSaved -Destination $quarantinedClone
        Invoke-CgceJournaledMove -Step "020-restore-original" `
            -Source $inactiveOriginal -Destination $activeSaved
    }
    "NO_ACTIVE_AND_INACTIVE_ORIGINAL" {
        Invoke-CgceJournaledMove -Step "020-restore-original" `
            -Source $inactiveOriginal -Destination $activeSaved
    }
    "ORIGINAL_ALREADY_ACTIVE" {
        Assert-CgceCompletedMoveReceipt -Step "020-restore-original"
    }
    default {
        throw "CGCE-OPS-MANUAL-RECOVERY ambiguous Saved layout"
    }
}

$restored = @(Get-CgceTreeInventory -Root $activeSaved)
Compare-CgceInventory -Expected $original -Actual $restored
if (Test-Path -LiteralPath $state.paths.probe_intent -PathType Leaf) {
    $probeRestore = @{
        Paths = $state.paths
        RunDirectory = $state.paths.run_directory
        RunId = $RunId
    }
    if ($null -ne $state.probe_receipt_checksum) {
        $probeRestore.ExpectedFinalReceiptChecksum =
            $state.probe_receipt_checksum
    }
    Restore-CgceInventoryProbe @probeRestore
}
$state.inventory_checksums.restored = Write-CgceInventory `
    -Entries $restored -Path $state.paths.restored_inventory -Kind "restored"
$state.phase = "RESTORED"
Write-CgceRunState -State $state -StatePath $statePath -ExpectedPhase "RESTORING"
Complete-CgceRunMarker -State $state
```

The helper names in this skeleton are private Task 6 helpers, not new entry
points. `Write-CgceRecoveryIntent` atomically creates
`000-restore-intent.json` before the first transition to `RESTORING` and records
the source phase, selected matrix case, and expected layouts/checksums. A crash
after intent creation but before the `RESTORING` state CAS resumes only when
the current phase still equals `intent.source_phase` and no operation receipt
exists. Once an intent exists, matrix evaluation is intent-bound rather than a
fresh-layout decision; this makes `UNCHANGED_ORIGINAL` and
`ORIGINAL_ALREADY_ACTIVE` resumable without weakening ambiguity checks. Do not
reuse the normal transition helper for crash recovery from intermediate phases.
After each
completed move or verified comparison, atomically create one numbered,
no-overwrite JSON receipt under `receipts\restore`.
`Invoke-CgceJournaledMove` recognizes a completed move only when the intent,
filesystem state, prior receipt checksum, source/destination inventory, and
intended step all agree. The Saved/probe/output quarantines are same-volume
sibling paths; `RunRoot` may be on a different backup volume.
`Complete-CgceRunMarker` no-overwrite moves the active marker to
`.cgce-discovery-completed-<run_id>.json` only after the RESTORED state
read-back. A crash before that move is resumed by calling restore again.
Hold the exclusive lock through the final `RESTORED` state read-back and
release it in `finally`.

- [ ] **Step 4: Add crash-point tests**

Create fixtures for every phase from `CREATED` through `RESTORED`, including
`RESTORING` after intent, after each move, and before/after each receipt.
Include missing active clone and pre-existing unrelated quarantine. Run the
backup root on a different synthetic volume when the Windows test host provides
one; otherwise assert all move pairs have the same volume root. Prove
deterministic restore or
`CGCE-OPS-MANUAL-RECOVERY`; assert original and backup are never deleted.

- [ ] **Step 5: Run GREEN and commit**

Run the Windows suite. Expected: restore/crash tests pass.

Commit:

```bash
git add tools/windows-discovery tests/windows
git commit -m "feat: restore Windows discovery production state"
```

---

### Task 7: Strict private evidence export

**Purpose:** restore가 검증된 run에서만 Saved/config를 제외한 private dump
artifact를 ZIP과 sidecar로 만든다.

**Files:**
- Create: `tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1`
- Modify: `tests/windows/Lifecycle.Tests.ps1`
- Create: `tools/windows-discovery/schemas/export-manifest.schema.json`

**Interfaces:**
- Consumes: phase `RESTORED`, control/run state, four inventory files,
  capture files.
- Produces:
  `CGCE-Windows-Discovery-<run_id>.zip`,
  `.zip.sha256`, phase `EXPORTED`, outcome `SUCCEEDED` for active runs.
- Error codes:
  `CGCE-OPS-EXPORT-PHASE`, `CGCE-OPS-EXPORT-ALLOWLIST`,
  `CGCE-OPS-EXPORT-SENSITIVE`, `CGCE-OPS-EXPORT-EXISTS`.

- [ ] **Step 1: Write failing export tests**

```powershell
Invoke-CgceTest "exports only after restore" {
    $fixture = New-CgceCapturedFixture
    Assert-CgceThrows "CGCE-OPS-EXPORT-PHASE" {
        & "$PSScriptRoot\..\..\tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1" `
            -RunRoot $fixture.RunRoot -RunId $fixture.RunId -OutputDirectory $fixture.OutputRoot
    }
}

Invoke-CgceTest "export never contains Saved or config" {
    $fixture = New-CgceRestoredFixture
    & "$PSScriptRoot\..\..\tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1" `
        -RunRoot $fixture.RunRoot -RunId $fixture.RunId -OutputDirectory $fixture.OutputRoot
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($fixture.ExportPath)
    $names = @($zip.Entries | ForEach-Object FullName)
    $zip.Dispose()
    Assert-CgceEqual 0 (@($names | Where-Object { $_ -match '(^|/)(Saved|config)(/|$)' })).Count
}
```

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: export script missing.

- [ ] **Step 3: Implement exact staging allowlist and manifest**

Read provisional state only to locate `server_root`, acquire the same
server-global lock, then re-read state and hold the lock through archive
read-back and the terminal state compare-and-swap. Require the exact completed
run marker and reject any still-active marker.

Allowed roots:

```text
control-evidence.json
run-state.json  # immutable RESTORED snapshot used as the export input
inventories/original.json
inventories/backup.json
inventories/clone.json
inventories/restored.json
capture/UE4SS_ObjectDump.txt
capture/CXXHeaderDump/**
export-manifest.json
```

Reject any source path containing `Saved`, `Config`, `mods.txt`, `.sav`, `.ini`,
`.key`, `.pem`, or a path outside the run directory. Validate that structured
JSON contains none of these fields:

```text
AdminPassword
ServerPassword
RCONPassword
RESTAPIKey
PrivateKey
```

Do not scan object/header dumps for property-name strings; those files are
allowed only from the exact capture paths and are private evidence.
Saved inventories contain no file bytes, but relative paths/hashes can include
pseudonymous world/player identifiers. Object/header dumps can also expose
private runtime names. The exporter therefore labels the archive private and
the runbook forbids committing, publishing, or attaching it to a public issue.

Create `export-manifest.json` with sorted `{relative_path,length,sha256}` entries
for every payload file except the manifest itself; the ZIP sidecar binds the
manifest. Archive a no-overwrite temp staging directory, hash the finished ZIP,
then write the sidecar. The archived `run-state.json` remains the exact
`RESTORED` input snapshot. Only after ZIP and sidecar read-back succeeds,
compare-and-swap the local run state to
`phase=EXPORTED,outcome=SUCCEEDED`.

Add `-Resume` for a crash after archive creation: it accepts an existing ZIP
and sidecar only when their checksums, exact entry allowlist, manifest, and
archived RESTORED state all match the current local RESTORED state. It may then
complete the same state transition without rebuilding or overwriting output.
Any mismatch blocks for manual inspection.

- [ ] **Step 4: Add rejection tests**

Prove export rejects missing restored inventory, path escape, added `.sav`,
structured secret field, unexpected existing output, resume checksum/entry
drift, and every `outcome=BLOCKED` run. Task 11A has no diagnostic-export mode;
blocked run directories remain private in place for manual inspection.

- [ ] **Step 5: Run GREEN and commit**

Run the Windows suite. Expected: export tests pass.

Commit:

```bash
git add tools/windows-discovery tests/windows
git commit -m "feat: export private Windows discovery evidence"
```

---

### Task 8: Deterministic macOS handoff builder and static verifier

**Purpose:** Windows에 전달할 exact source file set을 결정론적으로 패키징하고
DLL/save/private artifact 혼입을 정적으로 차단한다.

**Files:**
- Create: `scripts/verify-discovery-handoff.sh`
- Create: `scripts/build-discovery-handoff.sh`
- Modify: `tests/integration/discovery_handoff_spec.lua`
- Create: `tools/windows-discovery/README.md`

**Interfaces:**
- Produces:
  `dist/CGCE-Windows-Discovery-Handoff.zip`,
  `dist/CGCE-Windows-Discovery-Handoff.zip.sha256`.
- Consumes only the file map from the approved Task 11A spec.

- [ ] **Step 1: Extend the failing Lua static contract**

Assert:

```lua
local required = {
    "tools/windows-discovery/Prepare-CgceDiscovery.ps1",
    "tools/windows-discovery/Invoke-CgceDiscovery.ps1",
    "tools/windows-discovery/Restore-CgceProduction.ps1",
    "tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1",
    "scripts/verify-discovery-handoff.sh",
    "scripts/build-discovery-handoff.sh",
}
for _, path in ipairs(required) do
    local file = io.open(path, "rb")
    assert(file, path)
    file:close()
end
```

Apply forbidden checks by artifact type:

```text
handoff entries:
  case-insensitive *.dll extension

probe main.lua:
  ExecuteInGameThread
  SetPropertyValue
  ProcessConsoleExec

operator source under tools/windows-discovery (*.ps1 and *.psm1):
  Enter-PSSession
  Invoke-Command
  New-PSSession
  New-NetFirewallRule
  Set-NetFirewallRule
  Set-Service
  Start-Service
```

Do not reject explanatory occurrences in README/docs, and do not reject the
literal `UE4SS.dll` runtime preflight path. The test must distinguish bundled
binary entries from text that verifies an externally installed dependency.
Windows test files may mention forbidden names only as exact negative-test
fixtures; they are not part of the operator-source scan.

- [ ] **Step 2: Run RED**

Run:

```bash
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Expected: missing builder/verifier.

- [ ] **Step 3: Implement the static verifier**

`verify-discovery-handoff.sh` must:

1. call `scripts/verify-package.sh discovery`;
2. require every exact Task 11A artifact source plus the two repository-only
   builder/verifier scripts;
3. require every source path to pass `git ls-files --error-unmatch`;
4. reject symlinks;
5. reject unallowlisted files under `tools/windows-discovery` and `tests/windows`;
6. reject forbidden source patterns;
7. print `WINDOWS_DISCOVERY_HANDOFF_VERIFIED`.

The PowerShell `Assert-CgceHandoffSource` validator must parse the bundled
`source-manifest.sha256` as strict lowercase SHA-256 plus normalized relative
path records, reject duplicates/path escapes/unknown or missing entries, and
hash every extracted artifact source before prepare can create run state. Add
tampered, extra-entry, missing-entry, duplicate, and path-escape tests.

- [ ] **Step 4: Implement the deterministic builder**

Follow existing `scripts/build-release.sh` conventions:

```sh
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_path=${1:-"$repository_root/dist/CGCE-Windows-Discovery-Handoff.zip"}
"$repository_root/scripts/verify-discovery-handoff.sh"
test ! -e "$output_path"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/cgce-windows-discovery.XXXXXX")
```

Copy only exact artifact-allowlisted files, write sorted
`source-manifest.sha256` (the manifest does not list itself), set
directories `0755`, files `0644`, timestamps `198001010000`, and build with:

```sh
LC_ALL=C LANG=C find CGCE-Windows-Discovery-Handoff -type f -print |
    LC_ALL=C LANG=C sort |
    LC_ALL=C LANG=C zip -X -q "$output_path" -@
output_name=${output_path##*/}
(
    cd "$(dirname -- "$output_path")"
    LC_ALL=C LANG=C shasum -a 256 "$output_name"
) > "$output_path.sha256"
```

Run the `find`/`zip` pipeline from the staging root with
`LC_ALL=C LANG=C`, and ensure the sidecar records only `output_name`, never an
absolute path. This avoids Perl locale failures and makes sidecars from
different temporary directories byte-identical.

Refuse dirty included paths by checking:

```sh
test -z "$(git -C "$repository_root" status --porcelain=v1 -- \
    tools/windows-discovery \
    tests/windows \
    scripts/verify-discovery-handoff.sh \
    scripts/build-discovery-handoff.sh)"
```

The verifier must run `git ls-files --error-unmatch -- "$path"` for every
allowlisted input before this status check. This blocks both modified tracked
files and untracked files from entering the handoff.

- [ ] **Step 5: Run GREEN, commit, then verify from the clean commit**

Run focused and full Lua tests before the commit:

```bash
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
```

Expected: all pass.

Commit:

```bash
git add scripts tools/windows-discovery tests
git commit -m "feat: package Windows discovery handoff"
```

The handoff verifier intentionally requires tracked, clean inputs, so do not
claim its GREEN result from the pre-commit dirty worktree. Immediately after
the commit, run it and the deterministic build comparison in the clean
worktree:

```bash
./scripts/verify-discovery-handoff.sh
first=$(mktemp -d)/handoff.zip
second=$(mktemp -d)/handoff.zip
./scripts/build-discovery-handoff.sh "$first"
./scripts/build-discovery-handoff.sh "$second"
cmp "$first" "$second"
cmp "$first.sha256" "$second.sha256"
```

Expected: the verifier passes and both `cmp` commands exit `0`. If any
post-commit check fails, first add a regression test, make the smallest fix in a
new commit, and repeat this clean-worktree gate.

---

### Task 9: Synthetic end-to-end lifecycle and operator runbook

**Purpose:** 실제 server에 닿기 전에 temp tree에서
prepare → fake invoke → restore → export 전체를 증명하고, operator가 실행할
정확한 명령을 문서화한다.

**Files:**
- Modify: `tests/windows/Lifecycle.Tests.ps1`
- Create: `docs/windows-discovery-operator-runbook.md`
- Modify: `CrossplayGuildChestExpander/README.md`
- Modify: `docs/requirements-traceability.md`
- Modify: `docs/superpowers/plans/2026-07-22-cgce-implementation.md`

**Interfaces:**
- Produces one synthetic evidence ZIP whose sidecar verifies.
- Keeps Task 11A status `in progress` until Windows verification and the real
  restore-verified inventory run; Task 11B, Gate A, Tasks 12–14 remain blocked.

- [ ] **Step 1: Write the failing full lifecycle test**

```powershell
Invoke-CgceTest "full synthetic lifecycle restores original bytes" {
    $fixture = New-CgceSyntheticFixture
    $before = @(Get-CgceTreeInventory -Root $fixture.SavedPath)

    & $fixture.PrepareCommand
    & $fixture.InvokeCommand
    & $fixture.RestoreCommand
    & $fixture.ExportCommand

    $after = @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    Compare-CgceInventory -Expected $before -Actual $after

    $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    Assert-CgceEqual "EXPORTED" $state.phase
    Assert-CgceEqual "SUCCEEDED" $state.outcome
    Assert-CgceEqual $true (Test-Path $fixture.QuarantinedClone)
    Assert-CgceEqual $true (Test-Path $fixture.BackupSaved)
    Assert-CgceEqual $true (Test-Path $fixture.CompletedRunMarker)
    Assert-CgceEqual $false (Test-Path $fixture.ActiveRunMarker)
    Assert-CgceEqual $true (Test-Path $fixture.ExportPath)
}
```

- [ ] **Step 2: Run RED**

Run the Windows suite. Expected: full lifecycle assertion fails until all
entry-point receipts and fixtures converge.

- [ ] **Step 3: Complete fixture plumbing and run GREEN**

`FakePalServer.cmd` must contain only:

```bat
@echo off
setlocal
set "UE4SS_ROOT=%~1"
> "%UE4SS_ROOT%\UE4SS_ObjectDump.txt" <nul set /p ="synthetic object dump"
if not exist "%UE4SS_ROOT%\CXXHeaderDump" mkdir "%UE4SS_ROOT%\CXXHeaderDump"
> "%UE4SS_ROOT%\CXXHeaderDump\Synthetic.hpp" <nul set /p ="struct FSynthetic {};"
> "%UE4SS_ROOT%\UE4SS.log" <nul set /p ="CGCE_INVENTORY_COMPLETE ALL"
exit /b 0
```

The synthetic argument array is
`["/d","/c","<fixture-cmd-path>","<synthetic-ue4ss-root>"]`; fixture paths must
be chosen without spaces so they obey the same production argument grammar.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Expected: every test prints `PASS`; final summary reports `failures=0`.

- [ ] **Step 4: Write the operator runbook with exact commands**

Document these gates in order:

```powershell
$bundle = "D:\CGCE\CGCE-Windows-Discovery-Handoff.zip"
$bundleSidecar = "$bundle.sha256"
$extractionRoot = "D:\CGCE\Extracted-Handoff"
$handoffRoot = Join-Path $extractionRoot "CGCE-Windows-Discovery-Handoff"
$serverRoot = "D:\PalServer"
$savedPath = Join-Path $serverRoot "Pal\Saved"
$ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
$serverExecutable = Join-Path $serverRoot "PalServer.exe"
$runRoot = "E:\CGCE-Private-Runs"
$outputDirectory = "E:\CGCE-Private-Exports"
$argumentsPath = "D:\CGCE-Control\palserver-arguments.json"
$controlEvidencePath = "D:\CGCE-Control\control-evidence.json"
$runId = "r-0123456789abcdef0123456789abcdef"

$bundleSha256 = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedBundleSha256 = ((Get-Content -LiteralPath $bundleSidecar -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
if ($bundleSha256 -ne $expectedBundleSha256) { throw "handoff checksum mismatch" }
if (Test-Path -LiteralPath $extractionRoot) { throw "handoff extraction destination exists" }
Expand-Archive -LiteralPath $bundle -DestinationPath $extractionRoot
$sourceManifestPath = Join-Path $handoffRoot "source-manifest.sha256"
Import-Module (Join-Path $handoffRoot "tools\windows-discovery\modules\CgceDiscovery.Contract.psm1") -Force
Assert-CgceHandoffSource -HandoffRoot $handoffRoot -ManifestPath $sourceManifestPath

$controlEvidenceSha256 = (Get-FileHash -LiteralPath $controlEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $handoffRoot "tests\windows\Run-CgceDiscoveryTests.ps1")

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $handoffRoot "tools\windows-discovery\Prepare-CgceDiscovery.ps1") `
    -ServerRoot $serverRoot -SavedPath $savedPath -Ue4ssRoot $ue4ssRoot `
    -ServerExecutable $serverExecutable -RunRoot $runRoot -RunId $runId `
    -HandoffRoot $handoffRoot -SourceManifestPath $sourceManifestPath `
    -ControlEvidencePath $controlEvidencePath `
    -ControlEvidenceSha256 $controlEvidenceSha256 -BundleSha256 $bundleSha256

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $handoffRoot "tools\windows-discovery\Invoke-CgceDiscovery.ps1") `
    -RunRoot $runRoot -RunId $runId -ServerExecutable $serverExecutable `
    -ArgumentsPath $argumentsPath -TimeoutSeconds 1800

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $handoffRoot "tools\windows-discovery\Restore-CgceProduction.ps1") `
    -RunRoot $runRoot -RunId $runId

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $handoffRoot "tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1") `
    -RunRoot $runRoot -RunId $runId -OutputDirectory $outputDirectory
```

The runbook must state that the operator manually disables automatic restart,
blocks external access, performs normal test-server shutdown after the dump
marker, verifies restored inventory, and manually decides when to re-enable
production. It must include recovery commands for every blocked phase without
ever deleting backup/original/quarantine.

The paths above are a complete command-shape example, not discovered defaults.
The operator replaces them with canonical paths from the server and uses a
fresh random run ID. These commands run from an elevated Windows PowerShell
5.1 process only after checksum verification. The runbook must also show how
to create the exact control-evidence object from Task 1, compute the real UE4SS
DLL checksum, enumerate and review every launcher/server-child/crash-reporter
executable path below ServerRoot, set
`server_process_paths_complete=true` only after that review, set a maximum
four-hour UTC validity window, and create a dense JSON argument array containing
the server's reviewed non-secret/non-public arguments. Unknown descendant
images block the maintenance run; the operator does not guess the allowlist.
The runbook never copies credentials into the argument file.

- [ ] **Step 5: Align project status docs**

Confirm the master plan retains the already-established split and update only
the evidence/status links:

```text
Task 11A: Windows Discovery Operator lifecycle
Task 11B: Gate A exact observation and acceptance
```

Requirements traceability must say:

```text
Task 11A tool implementation complete only after Windows PowerShell 5.1 synthetic suite.
Task 11A operational complete only after a real restore-verified private inventory export.
Task 11B remains blocked until real inventory is reviewed.
No Gate A acceptance, mutation, Gate B, or release claim exists.
```

- [ ] **Step 6: Run pre-commit checks, commit, then run the clean gate**

On macOS before the commit:

```bash
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
git diff --check
```

Expected: all pass.

On Windows PowerShell `5.1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Expected: `failures=0`.

Commit:

```bash
git add docs CrossplayGuildChestExpander/README.md tests/windows
git commit -m "docs: add Windows discovery operator runbook"
```

Then, with all handoff inputs tracked and clean:

```bash
./scripts/verify-discovery-handoff.sh
./scripts/build-discovery-handoff.sh
git status --short
```

Expected: the verifier and builder pass; `git status --short` shows no
unexpected source change (an ignored `dist` artifact is allowed). If the clean
gate fails, add a regression, fix it in a follow-up commit, and rerun both
platform gates before reporting completion.

---

## Completion Gate

Implementation is complete only when all of the following are true:

- [ ] macOS full Lua suite passes.
- [ ] `scripts/verify-package.sh discovery` passes.
- [ ] static handoff verifier passes.
- [ ] two clean-worktree handoff builds are byte-identical.
- [ ] Windows PowerShell `5.1` synthetic suite reports `failures=0`.
- [ ] synthetic original inventory before prepare equals restored inventory.
- [ ] backup and quarantined clone still exist after success.
- [ ] active-run marker is absent and exact completed marker exists.
- [ ] evidence ZIP sidecar verifies and contains no Saved/config/credential file.
- [ ] production `main.lua` remains blocked without dependencies.
- [ ] release build remains blocked.
- [ ] no Gate A acceptance or public binding is generated.

The current macOS environment has no `pwsh`, so the Windows synthetic suite
cannot be substituted by a local static check. Until its output is returned
from the Windows host, implementation may be reported as “code complete,
Windows verification pending,” not “tool implementation complete.” After that
suite passes, Task 11A still remains operationally in progress until the
maintenance-window run restores the real original and exports the private
inventory.

## Operational Completion Gate

Task 11A is operationally complete only when one approved real Windows run also
proves:

- [ ] production restart remains disabled and external access remains blocked;
- [ ] full real Saved backup remains present and the original is restored at
  active `Pal\Saved` with its pre-run inventory;
- [ ] only the clone was started and only the inventory probe was enabled;
- [ ] the process and every observed descendant exited before restore;
- [ ] active Saved and UE4SS before-images match their pre-run inventories;
- [ ] active-run marker moved to the exact completed marker;
- [ ] the private evidence ZIP/sidecar verify on the development host;
- [ ] the result is recorded as non-authoritative input to Task 11B, with no
  Gate A acceptance or release claim.

## Plan Self-Review

- Spec coverage: build, prepare, invoke, restore, export, failure recovery,
  synthetic test, actual-server entry gate and non-goals each map to Tasks 1–9.
- Type consistency: run/control IDs, phase names, module signatures and output
  filenames are defined once in this plan and reused unchanged.
- Mutation boundary: no task modifies production bootstrap or adds game-state
  mutation APIs.
- Platform boundary: macOS performs deterministic source packaging; Windows
  PowerShell `5.1` performs lifecycle validation; neither requires a compiler.
- Gate boundary: Task 11A ends at non-authoritative inventory export; Gate A,
  fatal behavior, client certification and release remain later work.
