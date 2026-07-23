Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1" -Force

function New-CgceContractTestRoot {
    $root = Join-Path $env:TEMP ("cgce-contract-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

function Write-CgceContractTestUtf8([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function New-CgceContractTestPaths([string]$Root) {
    $runId = "r-0123456789abcdef0123456789abcdef"
    $runDirectory = Join-Path $Root $runId
    return [pscustomobject][ordered]@{
        server_root = (Join-Path $Root "server")
        run_root = $Root
        run_directory = $runDirectory
        state = (Join-Path $runDirectory "run-state.json")
        genesis_state = (Join-Path $runDirectory "run-state.genesis.json")
        control_evidence = (Join-Path $runDirectory "control-evidence.json")
        active_run_marker = (Join-Path (Join-Path $Root "server") ".cgce-discovery-active.json")
        completed_run_marker = (Join-Path (Join-Path $Root "server") ".cgce-discovery-completed-$runId.json")
        active_saved = (Join-Path (Join-Path $Root "server") "Pal\Saved")
        inactive_original = (Join-Path (Join-Path $Root "server") "Pal\Saved.cgce-original-$runId")
        quarantined_clone = (Join-Path (Join-Path $Root "server") "Pal\Saved.cgce-test-$runId")
        backup_saved = (Join-Path $runDirectory "backup\Saved")
        original_inventory = (Join-Path $runDirectory "inventories\original.json")
        backup_inventory = (Join-Path $runDirectory "inventories\backup.json")
        clone_inventory = (Join-Path $runDirectory "inventories\clone.json")
        restored_inventory = (Join-Path $runDirectory "inventories\restored.json")
        ue4ss_root = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64")
        ue4ss_dll = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS.dll")
        mods_txt = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\Mods\mods.txt")
        mods_original = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\Mods\mods.txt.cgce-original-$runId")
        mods_test = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\Mods\mods.txt.cgce-test-$runId")
        probe_staged = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\Mods\CGCEDiscoveryInventory")
        probe_quarantine = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\Mods\CGCEDiscoveryInventory.cgce-test-$runId")
        object_dump = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS_ObjectDump.txt")
        object_dump_original = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS_ObjectDump.txt.cgce-original-$runId")
        object_dump_quarantine = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS_ObjectDump.txt.cgce-test-$runId")
        cxx_header_dump = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\CXXHeaderDump")
        cxx_header_dump_original = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\CXXHeaderDump.cgce-original-$runId")
        cxx_header_dump_quarantine = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\CXXHeaderDump.cgce-test-$runId")
        ue4ss_log = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS.log")
        ue4ss_log_original = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS.log.cgce-original-$runId")
        ue4ss_log_quarantine = (Join-Path (Join-Path $Root "server") "Pal\Binaries\Win64\UE4SS.log.cgce-test-$runId")
        capture = (Join-Path $runDirectory "capture")
        probe_intent = (Join-Path $runDirectory "receipts\probe\000-probe-intent.json")
        probe_receipt = (Join-Path $runDirectory "receipts\probe\999-probe-final.json")
        probe_receipts = (Join-Path $runDirectory "receipts\probe")
        process_launch_receipt = (Join-Path $runDirectory "receipts\process\000-launch.json")
        process_result_receipt = (Join-Path $runDirectory "receipts\process\999-result.json")
        process_receipts = (Join-Path $runDirectory "receipts\process")
        capture_inventory = (Join-Path $runDirectory "capture-inventory.json")
        restore_receipts = (Join-Path $runDirectory "receipts\restore")
    }
}

function New-CgceContractTestControl {
    return [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_control"
        maintenance_id = "m-0123456789abcdef0123456789abcdef"
        run_id = "r-0123456789abcdef0123456789abcdef"
        operator = "operator"
        server_root = "D:\PalServer"
        palserver_executable = "D:\PalServer\PalServer.exe"
        server_process_paths = @(
            "D:\PalServer\PalServer.exe",
            "D:\PalServer\Pal\Binaries\Win64\PalServer-Win64-Test-Cmd.exe"
        )
        server_process_paths_complete = $true
        ue4ss_root = "D:\PalServer\Pal\Binaries\Win64"
        ue4ss_version = "3.0.1"
        ue4ss_dll_sha256 = ("b" * 64)
        listener_ports = @(8211, 27015)
        production_restart_disabled = $true
        external_access_blocked = $true
        players_disconnected = $true
        bundle_checksum = ("a" * 64)
        verified_at_utc = "2026-07-23T00:00:00Z"
        valid_until_utc = "2026-07-23T04:00:00Z"
    }
}

function Write-CgceContractTestControl([string]$Path, $Value) {
    Write-CgceContractTestUtf8 -Path $Path -Text ($Value | ConvertTo-Json -Depth 8)
}

function Set-CgceContractCreatedEvidence($State) {
    $State.inventory_checksums.original = ("1" * 64)
}

function New-CgceContractTestMarkerFixture([string]$Root) {
    $paths = New-CgceContractTestPaths $Root
    New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
    New-Item -ItemType Directory -Path $paths.server_root | Out-Null
    $state = New-CgceRunState `
        -RunId "r-0123456789abcdef0123456789abcdef" `
        -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
        -Paths $paths
    $state.bundle_checksum = ("a" * 64)
    $state.control_evidence_checksum = ("b" * 64)
    $state.palserver_executable = (Join-Path $paths.server_root "PalServer.exe")
    $state.palserver_executable_checksum = ("c" * 64)
    $state.ue4ss_version = "3.0.1"
    $state.server_process_paths = @(
        (Join-Path $paths.server_root "PalServer.exe"),
        (Join-Path $paths.server_root "Pal\Binaries\Win64\PalServer-Win64-Test-Cmd.exe")
    )
    $state.ue4ss_dll_checksum = ("d" * 64)
    $state.listener_ports = @(8211, 27015)
    Set-CgceContractCreatedEvidence $state
    Write-CgceJsonAtomic $state $paths.genesis_state
    Write-CgceJsonAtomic $state $paths.state
    $marker = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_run_marker"
        run_id = $state.run_id
        run_root = $state.paths.run_root
        genesis_state_checksum = (Get-CgceSha256 $paths.genesis_state)
    }
    Write-CgceJsonAtomic $marker $paths.active_run_marker
    return [pscustomobject]@{
        paths = $paths
        state = $state
    }
}

Invoke-CgceTest "accepts only fixed run ids" {
    Assert-CgceEqual $true (Test-CgceRunId "r-0123456789abcdef0123456789abcdef")
    Assert-CgceEqual $false (Test-CgceRunId "r-0123456789ABCDEF0123456789abcdef")
    Assert-CgceEqual $false (Test-CgceRunId "..\escape")
}

Invoke-CgceTest "rejects skipped phases" {
    $state = [pscustomobject]@{ phase = "CREATED"; outcome = "ACTIVE" }
    Assert-CgceThrows "CGCE-OPS-PHASE" {
        Set-CgceRunPhase -State $state -ExpectedPhase "BACKUP_VERIFIED" -NextPhase "CLONE_ACTIVE"
    }
}

Invoke-CgceTest "strict JSON preserves root kinds and one-element arrays" {
    $root = New-CgceContractTestRoot
    try {
        $objectPath = Join-Path $root "object.json"
        $objectArrayPath = Join-Path $root "object-array.json"
        $stringPath = Join-Path $root "string.json"
        $stringArrayPath = Join-Path $root "string-array.json"
        Write-CgceContractTestUtf8 $objectPath "{}"
        Write-CgceContractTestUtf8 $objectArrayPath "[{}]"
        Write-CgceContractTestUtf8 $stringPath '"x"'
        Write-CgceContractTestUtf8 $stringArrayPath '["x"]'

        Assert-CgceEqual 0 @((Read-CgceJsonObject $objectPath).PSObject.Properties).Count
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $objectArrayPath }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $stringPath }
        $values = @(Read-CgceJsonStringArray $stringArrayPath)
        Assert-CgceEqual 1 $values.Count
        Assert-CgceEqual "x" $values[0]
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "strict JSON rejects duplicate and unrepresentable case-variant keys" {
    $root = New-CgceContractTestRoot
    try {
        $duplicatePath = Join-Path $root "duplicate.json"
        $casePath = Join-Path $root "case.json"
        Write-CgceContractTestUtf8 $duplicatePath '{"key":1,"key":2}'
        Write-CgceContractTestUtf8 $casePath '{"key":1,"KEY":2}'
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $duplicatePath }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $casePath }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "strict JSON rejects malformed UTF-8 surrogates numbers and trailing input" {
    $root = New-CgceContractTestRoot
    try {
        $invalidUtf8 = Join-Path $root "utf8.json"
        $invalidSurrogate = Join-Path $root "surrogate.json"
        $invalidNumber = Join-Path $root "number.json"
        $trailing = Join-Path $root "trailing.json"
        [System.IO.File]::WriteAllBytes($invalidUtf8, [byte[]]@(0x7b, 0x22, 0x78, 0x22, 0x3a, 0xc3, 0x28, 0x7d))
        Write-CgceContractTestUtf8 $invalidSurrogate '{"x":"\uD800"}'
        Write-CgceContractTestUtf8 $invalidNumber '{"x":01}'
        Write-CgceContractTestUtf8 $trailing '{} true'
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $invalidUtf8 }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $invalidSurrogate }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $invalidNumber }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $trailing }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "strict JSON enforces 1048576 bytes and depth 64" {
    $root = New-CgceContractTestRoot
    try {
        $atLimit = Join-Path $root "at-limit.json"
        $overLimit = Join-Path $root "over-limit.json"
        $depth64 = Join-Path $root "depth64.json"
        $depth65 = Join-Path $root "depth65.json"
        Write-CgceContractTestUtf8 $atLimit ('{"x":"' + ("a" * 1048568) + '"}')
        Write-CgceContractTestUtf8 $overLimit ('{"x":"' + ("a" * 1048569) + '"}')
        Write-CgceContractTestUtf8 $depth64 ('{"x":' + ("[" * 63) + '"x"' + ("]" * 63) + "}")
        Write-CgceContractTestUtf8 $depth65 ('{"x":' + ("[" * 64) + '"x"' + ("]" * 64) + "}")
        Assert-CgceEqual 1048576 ([System.IO.FileInfo]$atLimit).Length
        $null = Read-CgceJsonObject $atLimit
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $overLimit }
        $null = Read-CgceJsonObject $depth64
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $depth65 }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "validates exact control evidence" {
    $root = New-CgceContractTestRoot
    try {
        $path = Join-Path $root "control.json"
        $control = New-CgceContractTestControl
        Write-CgceContractTestControl $path $control
        $sha = Get-CgceSha256 $path
        $validated = Assert-CgceControlEvidence `
            -EvidencePath $path `
            -ExpectedFileChecksum $sha `
            -ExpectedBundleChecksum ("a" * 64) `
            -NowUtc ([DateTime]::Parse("2026-07-23T02:00:00Z").ToUniversalTime())
        Assert-CgceEqual $control.run_id $validated.run_id
        Assert-CgceEqual 2 @($validated.server_process_paths).Count
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "rejects control drift incomplete paths and expiration" {
    $root = New-CgceContractTestRoot
    try {
        $path = Join-Path $root "control.json"
        $control = New-CgceContractTestControl
        $control.server_process_paths_complete = $false
        Write-CgceContractTestControl $path $control
        $sha = Get-CgceSha256 $path
        Assert-CgceThrows "CGCE-OPS-CONTROL" {
            Assert-CgceControlEvidence $path $sha ("a" * 64) ([DateTime]::Parse("2026-07-23T02:00:00Z"))
        }

        $control.server_process_paths_complete = $true
        Write-CgceContractTestControl $path $control
        $sha = Get-CgceSha256 $path
        Assert-CgceThrows "CGCE-OPS-CONTROL-EXPIRED" {
            Assert-CgceControlEvidence $path $sha ("a" * 64) ([DateTime]::Parse("2026-07-23T04:00:01Z"))
        }
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceControlEvidence $path ("f" * 64) ("a" * 64) ([DateTime]::Parse("2026-07-23T02:00:00Z"))
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "atomic JSON creates UTF-8 without BOM and never overwrites ordinary output" {
    $root = New-CgceContractTestRoot
    try {
        $path = Join-Path $root "output.json"
        Write-CgceJsonAtomic -Value ([pscustomobject]@{ value = "ok" }) -Path $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-CgceEqual $false ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)
        Assert-CgceThrows "CGCE-OPS-OUTPUT-EXISTS" {
            Write-CgceJsonAtomic -Value ([pscustomobject]@{ value = "changed" }) -Path $path
        }
        Assert-CgceEqual "ok" (Read-CgceJsonObject $path).value
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "atomic JSON rejects existing temp and checksum drift without deleting destination" {
    $root = New-CgceContractTestRoot
    try {
        $path = Join-Path $root "run-state.json"
        Write-CgceContractTestUtf8 $path '{"value":"old"}'
        $oldSha = Get-CgceSha256 $path
        Write-CgceContractTestUtf8 ($path + ".tmp") '{}'
        Assert-CgceThrows "CGCE-OPS-OUTPUT-EXISTS" {
            Write-CgceJsonAtomic -Value ([pscustomobject]@{ value = "new" }) -Path $path -ExpectedExistingSha256 $oldSha
        }
        Assert-CgceEqual "old" (Read-CgceJsonObject $path).value
        Remove-Item -LiteralPath ($path + ".tmp")
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceJsonAtomic -Value ([pscustomobject]@{ value = "new" }) -Path $path -ExpectedExistingSha256 ("f" * 64)
        }
        Assert-CgceEqual "old" (Read-CgceJsonObject $path).value
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "new run state has every exact field and state replacement increments once" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Assert-CgceEqual "CREATED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Assert-CgceEqual 0 $state.revision
        Assert-CgceEqual 24 @($state.PSObject.Properties).Count
        Assert-CgceEqual 41 @($state.paths.PSObject.Properties).Count
        Assert-CgceEqual 4 @($state.inventory_checksums.PSObject.Properties).Count
        Assert-CgceEqual $null $state.inventory_checksums.original
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state

        $state.inventory_checksums.backup = ("2" * 64)
        $state = Set-CgceRunPhase $state "CREATED" "BACKUP_VERIFIED"
        Write-CgceRunState -State $state -StatePath $paths.state -ExpectedPhase "CREATED"
        $read = Read-CgceRunState -RunRoot $root -RunId $state.run_id
        Assert-CgceEqual "BACKUP_VERIFIED" $read.phase
        Assert-CgceEqual 1 $read.revision
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state replacement reopens new state while preserving the old file handle" {
    $root = New-CgceContractTestRoot
    $oldHandle = $null
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $oldHandle = [System.IO.File]::Open(
            $paths.state,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $share
        )

        $state.inventory_checksums.backup = ("2" * 64)
        $state = Set-CgceRunPhase $state "CREATED" "BACKUP_VERIFIED"
        Write-CgceRunState -State $state -StatePath $paths.state -ExpectedPhase "CREATED"

        Assert-CgceEqual $true (Test-Path -LiteralPath $paths.state -PathType Leaf)
        Assert-CgceEqual $false (Test-Path -LiteralPath ($paths.state + ".tmp"))
        $reopened = Read-CgceRunState -RunRoot $root -RunId $state.run_id
        Assert-CgceEqual "BACKUP_VERIFIED" $reopened.phase
        Assert-CgceEqual 1 $reopened.revision

        $oldHandle.Position = 0
        $oldBytes = New-Object byte[] $oldHandle.Length
        $null = $oldHandle.Read($oldBytes, 0, $oldBytes.Length)
        $oldText = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($oldBytes)
        Assert-CgceEqual $true $oldText.Contains("CREATED")
        Assert-CgceEqual $false $oldText.Contains("BACKUP_VERIFIED")
    } finally {
        if ($null -ne $oldHandle) { $oldHandle.Dispose() }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state replacement surfaces an injected reopen failure without deleting state" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state
        $state.inventory_checksums.backup = ("2" * 64)
        $state = Set-CgceRunPhase $state "CREATED" "BACKUP_VERIFIED"

        $module = Get-Module "CgceDiscovery.Contract"
        & $module {
            Set-Item -Path Function:script:Read-CgceRunStateAfterReplace -Value {
                param([string]$Path)
                throw "CGCE-OPS-JSON injected read-back failure"
            }
        }
        Assert-CgceThrows "CGCE-OPS-JSON" {
            Write-CgceRunState -State $state -StatePath $paths.state -ExpectedPhase "CREATED"
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath $paths.state -PathType Leaf)
        Assert-CgceEqual $false (Test-Path -LiteralPath ($paths.state + ".tmp"))

        Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1" -Force
        $persisted = Read-CgceRunState -RunRoot $root -RunId $state.run_id
        Assert-CgceEqual "BACKUP_VERIFIED" $persisted.phase
        Assert-CgceEqual 1 $persisted.revision
    } finally {
        Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1" -Force
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state rejects unknown and missing fields" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        $state | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        Write-CgceJsonAtomic $state $paths.state
        Assert-CgceThrows "CGCE-OPS-JSON" {
            Read-CgceRunState -RunRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }
        $state.PSObject.Properties.Remove("unexpected")
        $state.PSObject.Properties.Remove("errors")
        Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-JSON" {
            Read-CgceRunState -RunRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state rejects identity drift non-monotonic revision and early receipts" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state

        $state.maintenance_id = "m-fedcba9876543210fedcba9876543210"
        Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Read-CgceRunState -RunRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }

        $state.maintenance_id = "m-0123456789abcdef0123456789abcdef"
        $state.revision = -1
        Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Read-CgceRunState -RunRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }

        $state.revision = 0
        $state.probe_receipt_checksum = ("a" * 64)
        Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Read-CgceRunState -RunRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state accepts only null or exact UE4SS 3.0.1" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        $state.ue4ss_version = "3.0.1"
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state
        Assert-CgceEqual "3.0.1" (Read-CgceRunState $root $state.run_id).ue4ss_version

        foreach ($invalid in @("3.0.10", "V3.0.1", "3.0.1 ")) {
            $state.ue4ss_version = $invalid
            Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-JSON" {
                Read-CgceRunState $root $state.run_id
            }
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "normal state writer enforces checkpoint introduction and immutable checksum authority" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state

        $missingBackup = Read-CgceJsonObject $paths.state
        $missingBackup = Set-CgceRunPhase $missingBackup "CREATED" "BACKUP_VERIFIED"
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Write-CgceRunState $missingBackup $paths.state "CREATED"
        }

        $earlyClone = Read-CgceJsonObject $paths.state
        $earlyClone.inventory_checksums.backup = ("2" * 64)
        $earlyClone.inventory_checksums.clone = ("3" * 64)
        $earlyClone = Set-CgceRunPhase $earlyClone "CREATED" "BACKUP_VERIFIED"
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Write-CgceRunState $earlyClone $paths.state "CREATED"
        }

        $backupVerified = Read-CgceJsonObject $paths.state
        $backupVerified.inventory_checksums.backup = ("2" * 64)
        $backupVerified = Set-CgceRunPhase $backupVerified "CREATED" "BACKUP_VERIFIED"
        Write-CgceRunState $backupVerified $paths.state "CREATED"

        $drift = Read-CgceJsonObject $paths.state
        $drift.inventory_checksums.backup = ("f" * 64)
        $drift = Set-CgceRunPhase $drift "BACKUP_VERIFIED" "ORIGINAL_DEACTIVATED"
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceRunState $drift $paths.state "BACKUP_VERIFIED"
        }

        $errorInjection = Read-CgceJsonObject $paths.state
        $errorInjection.errors = @(
            [pscustomobject]@{
                code = "CGCE-OPS-BLOCKED"
                at_utc = "2026-07-23T00:00:00Z"
            }
        )
        $errorInjection = Set-CgceRunPhase `
            $errorInjection "BACKUP_VERIFIED" "ORIGINAL_DEACTIVATED"
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Write-CgceRunState $errorInjection $paths.state "BACKUP_VERIFIED"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "committed states require the exact checkpoint evidence table" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $genesis = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $genesis
        Write-CgceJsonAtomic $genesis $paths.genesis_state

        $cases = @(
            @{ phase = "CREATED"; missing = "original" },
            @{ phase = "BACKUP_VERIFIED"; missing = "backup" },
            @{ phase = "ORIGINAL_DEACTIVATED"; missing = "backup" },
            @{ phase = "CLONE_ACTIVE"; missing = "clone" },
            @{ phase = "PROBE_STAGED"; missing = "probe" },
            @{ phase = "RUNNING"; missing = "probe" },
            @{ phase = "CAPTURED"; missing = "launch" },
            @{ phase = "CAPTURED"; missing = "result" },
            @{ phase = "CAPTURED"; missing = "capture" },
            @{ phase = "RESTORED"; missing = "restored" }
        )
        foreach ($case in $cases) {
            $state = Read-CgceJsonObject $paths.genesis_state
            $state.phase = $case.phase
            $state.revision = [Array]::IndexOf(@(
                "CREATED", "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED",
                "CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED",
                "RESTORING", "RESTORED", "EXPORTED"
            ), $case.phase)
            $state.inventory_checksums.backup = ("2" * 64)
            $state.inventory_checksums.clone = ("3" * 64)
            $state.probe_receipt_checksum = ("4" * 64)
            $state.process_launch_receipt_checksum = ("5" * 64)
            $state.process_result_receipt_checksum = ("6" * 64)
            $state.capture_inventory_checksum = ("7" * 64)
            $state.inventory_checksums.restored = ("8" * 64)
            switch ($case.missing) {
                "original" { $state.inventory_checksums.original = $null }
                "backup" { $state.inventory_checksums.backup = $null }
                "clone" { $state.inventory_checksums.clone = $null }
                "probe" { $state.probe_receipt_checksum = $null }
                "launch" { $state.process_launch_receipt_checksum = $null }
                "result" { $state.process_result_receipt_checksum = $null }
                "capture" { $state.capture_inventory_checksum = $null }
                "restored" { $state.inventory_checksums.restored = $null }
            }
            foreach ($field in @(
                @{ name = "backup"; minimum = 1 },
                @{ name = "clone"; minimum = 3 },
                @{ name = "restored"; minimum = 8 }
            )) {
                if ($state.revision -lt $field.minimum) {
                    $state.inventory_checksums.($field.name) = $null
                }
            }
            foreach ($field in @(
                @{ name = "probe_receipt_checksum"; minimum = 4 },
                @{ name = "process_launch_receipt_checksum"; minimum = 6 },
                @{ name = "process_result_receipt_checksum"; minimum = 6 },
                @{ name = "capture_inventory_checksum"; minimum = 6 }
            )) {
                if ($state.revision -lt $field.minimum) {
                    $state.($field.name) = $null
                }
            }
            Write-CgceContractTestUtf8 $paths.state ($state | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-PHASE" {
                Read-CgceRunState $root $state.run_id
            }
        }

        $blockedRunning = Read-CgceJsonObject $paths.genesis_state
        $blockedRunning.phase = "RUNNING"
        $blockedRunning.revision = 5
        $blockedRunning.inventory_checksums.backup = ("2" * 64)
        $blockedRunning.inventory_checksums.clone = ("3" * 64)
        $blockedRunning.probe_receipt_checksum = ("4" * 64)
        $blockedRunning.outcome = "BLOCKED"
        $blockedRunning.errors = @(
            [pscustomobject]@{
                code = "CGCE-OPS-BLOCKED"
                at_utc = "2026-07-23T00:00:00Z"
            }
        )
        Write-CgceContractTestUtf8 `
            $paths.state `
            ($blockedRunning | ConvertTo-Json -Depth 12)
        Assert-CgceEqual `
            "BLOCKED" `
            (Read-CgceRunState $root $blockedRunning.run_id).outcome
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "normal state writer preserves every previously non-null checksum" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $genesis = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $genesis
        Write-CgceJsonAtomic $genesis $paths.genesis_state
        $state = Read-CgceJsonObject $paths.genesis_state
        $state.phase = "RESTORED"
        $state.revision = 8
        $state.inventory_checksums.backup = ("2" * 64)
        $state.inventory_checksums.clone = ("3" * 64)
        $state.probe_receipt_checksum = ("4" * 64)
        $state.process_launch_receipt_checksum = ("5" * 64)
        $state.process_result_receipt_checksum = ("6" * 64)
        $state.capture_inventory_checksum = ("7" * 64)
        $state.inventory_checksums.restored = ("8" * 64)
        Write-CgceJsonAtomic $state $paths.state

        $mutations = @(
            { param($Value) $Value.inventory_checksums.original = ("a" * 64) },
            { param($Value) $Value.inventory_checksums.backup = ("a" * 64) },
            { param($Value) $Value.inventory_checksums.clone = ("a" * 64) },
            { param($Value) $Value.inventory_checksums.restored = ("a" * 64) },
            { param($Value) $Value.probe_receipt_checksum = ("a" * 64) },
            { param($Value) $Value.process_launch_receipt_checksum = ("a" * 64) },
            { param($Value) $Value.process_result_receipt_checksum = ("a" * 64) },
            { param($Value) $Value.capture_inventory_checksum = ("a" * 64) }
        )
        foreach ($mutation in $mutations) {
            $candidate = Read-CgceJsonObject $paths.state
            $null = & $mutation $candidate
            $candidate.phase = "EXPORTED"
            $candidate.outcome = "SUCCEEDED"
            Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
                Write-CgceRunState $candidate $paths.state "RESTORED"
            }
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "original checksum is immutable genesis identity" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        $state.inventory_checksums.original = ("9" * 64)
        Write-CgceJsonAtomic $state $paths.state
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Read-CgceRunState $root $state.run_id
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "blocked state CAS rereads authority appends once and cannot resume through the normal writer" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state
        Write-CgceActiveRunMarker `
            -State $state `
            -GenesisStateChecksum (Get-CgceSha256 $paths.genesis_state) `
            -Path $paths.active_run_marker

        $stale = Read-CgceJsonObject $paths.state
        $stale.phase = "BACKUP_VERIFIED"
        $blocked = Block-CgceRunState `
            -StatePath $paths.state `
            -Code "CGCE-OPS-BACKUP"
        Assert-CgceEqual "CREATED" $blocked.phase
        Assert-CgceEqual "BLOCKED" $blocked.outcome
        Assert-CgceEqual 1 @($blocked.errors).Count
        Assert-CgceEqual "CGCE-OPS-BACKUP" $blocked.errors[0].code
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Block-CgceRunState `
                -StatePath $paths.state `
                -Code "CGCE-OPS-BACKUP"
        }
        $read = Read-CgceRunState $root $state.run_id
        Assert-CgceEqual 1 @($read.errors).Count

        $read.inventory_checksums.backup = ("2" * 64)
        $read = Set-CgceRunPhase $read "CREATED" "BACKUP_VERIFIED"
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Write-CgceRunState $read $paths.state "CREATED"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "blocked transition cannot introduce a compatible null checksum" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $genesis = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $genesis
        Write-CgceJsonAtomic $genesis $paths.genesis_state
        $running = Read-CgceJsonObject $paths.genesis_state
        $running.phase = "RUNNING"
        $running.revision = 5
        $running.inventory_checksums.backup = ("2" * 64)
        $running.inventory_checksums.clone = ("3" * 64)
        $running.probe_receipt_checksum = ("4" * 64)
        Write-CgceJsonAtomic $running $paths.state
        Write-CgceActiveRunMarker `
            -State $running `
            -GenesisStateChecksum (Get-CgceSha256 $paths.genesis_state) `
            -Path $paths.active_run_marker

        $blocked = Read-CgceJsonObject $paths.state
        $blocked.outcome = "BLOCKED"
        $blocked.process_launch_receipt_checksum = ("5" * 64)
        $blocked.errors = @(
            [pscustomobject]@{
                code = "CGCE-OPS-BLOCKED"
                at_utc = "2026-07-23T00:00:00Z"
            }
        )
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceRunState $blocked $paths.state "RUNNING"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "blocked state CAS refuses marker drift without overwriting authority" {
    $root = New-CgceContractTestRoot
    try {
        $fixture = New-CgceContractTestMarkerFixture $root
        $marker = Read-CgceJsonObject $fixture.paths.active_run_marker
        $marker.genesis_state_checksum = ("f" * 64)
        Write-CgceContractTestUtf8 `
            $fixture.paths.active_run_marker `
            ($marker | ConvertTo-Json -Depth 4)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Block-CgceRunState `
                -StatePath $fixture.paths.state `
                -Code "CGCE-OPS-BLOCKED"
        }
        $current = Read-CgceJsonObject $fixture.paths.state
        Assert-CgceEqual "ACTIVE" $current.outcome
        Assert-CgceEqual 0 @($current.errors).Count
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run marker binds the immutable genesis and has exactly one location" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Set-CgceContractCreatedEvidence $state
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state
        $genesisChecksum = Get-CgceSha256 $paths.genesis_state
        Write-CgceActiveRunMarker `
            -State $state `
            -GenesisStateChecksum $genesisChecksum `
            -Path $paths.active_run_marker
        $marker = Read-CgceJsonObject $paths.active_run_marker
        Assert-CgceEqual 5 @($marker.PSObject.Properties).Count
        Assert-CgceEqual $genesisChecksum $marker.genesis_state_checksum
        Assert-CgceThrows "CGCE-OPS-OUTPUT-EXISTS" {
            Write-CgceActiveRunMarker `
                -State $state `
                -GenesisStateChecksum $genesisChecksum `
                -Path $paths.active_run_marker
        }
        Assert-CgceRunMarker -State $state
        Write-CgceJsonAtomic $marker $paths.completed_run_marker
        Assert-CgceThrows "CGCE-OPS-CONTROL" {
            Assert-CgceRunMarker -State $state -AllowCompleted
        }
        Remove-Item -LiteralPath $paths.active_run_marker
        Assert-CgceRunMarker -State $state -AllowCompleted
        Write-CgceContractTestUtf8 $paths.genesis_state "{}"
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceRunMarker -State $state -AllowCompleted
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run marker rejects immutable checksum identity drift" {
    $root = New-CgceContractTestRoot
    try {
        $fixture = New-CgceContractTestMarkerFixture $root
        $fixture.state.bundle_checksum = ("e" * 64)
        Write-CgceContractTestUtf8 $fixture.paths.state ($fixture.state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceRunMarker -State $fixture.state
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run marker rejects immutable path identity drift" {
    $root = New-CgceContractTestRoot
    try {
        $fixture = New-CgceContractTestMarkerFixture $root
        $fixture.state.paths.capture = (Join-Path $fixture.paths.run_directory "other-capture")
        Write-CgceContractTestUtf8 $fixture.paths.state ($fixture.state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceRunMarker -State $fixture.state
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run marker rejects immutable process-list identity drift" {
    $root = New-CgceContractTestRoot
    try {
        $fixture = New-CgceContractTestMarkerFixture $root
        $fixture.state.server_process_paths = @(
            $fixture.state.server_process_paths[0],
            (Join-Path $fixture.paths.server_root "unexpected.exe")
        )
        Write-CgceContractTestUtf8 $fixture.paths.state ($fixture.state | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceRunMarker -State $fixture.state
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "handoff manifest accepts only the exact sorted payload allowlist" {
    $root = New-CgceContractTestRoot
    try {
        $paths = @(
            "tests/windows/Contract.Tests.ps1",
            "tests/windows/Files.Tests.ps1",
            "tests/windows/fixtures/FakePalServer.cmd",
            "tests/windows/Lifecycle.Tests.ps1",
            "tests/windows/Run-CgceDiscoveryTests.ps1",
            "tests/windows/Runtime.Tests.ps1",
            "tests/windows/TestHarness.ps1",
            "tools/windows-discovery/CgceDiscovery.Common.psm1",
            "tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1",
            "tools/windows-discovery/Invoke-CgceDiscovery.ps1",
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1",
            "tools/windows-discovery/modules/CgceDiscovery.Files.psm1",
            "tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1",
            "tools/windows-discovery/Prepare-CgceDiscovery.ps1",
            "tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua",
            "tools/windows-discovery/README.md",
            "tools/windows-discovery/Restore-CgceProduction.ps1",
            "tools/windows-discovery/schemas/control-evidence.schema.json",
            "tools/windows-discovery/schemas/export-manifest.schema.json",
            "tools/windows-discovery/schemas/run-state.schema.json"
        )
        [Array]::Sort($paths, [StringComparer]::Ordinal)
        $records = New-Object System.Collections.Generic.List[string]
        foreach ($relative in $paths) {
            $native = Join-Path $root ($relative -replace '/', '\')
            $parent = Split-Path -Parent $native
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Write-CgceContractTestUtf8 $native $relative
            $records.Add((Get-CgceSha256 $native) + "  " + $relative)
        }
        $manifest = Join-Path $root "source-manifest.sha256"
        Write-CgceContractTestUtf8 $manifest (($records -join "`n") + "`n")
        Assert-CgceHandoffSource -HandoffRoot $root -ManifestPath $manifest

        $records[1] = ("0" * 64) + "  " + $paths[1]
        Write-CgceContractTestUtf8 $manifest (($records -join "`n") + "`n")
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceHandoffSource -HandoffRoot $root -ManifestPath $manifest
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "exclusive lock blocks a second process without changing lock contents" {
    $root = New-CgceContractTestRoot
    $process = $null
    try {
        $module = (Resolve-Path "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1").Path
        $holder = Join-Path $root "hold-lock.ps1"
        $ready = Join-Path $root "ready"
        $holderText = @"
param([string]`$Module, [string]`$Root, [string]`$Ready)
Import-Module `$Module -Force
`$lock = Enter-CgceExclusiveLock -ServerRoot `$Root -RunId "r-0123456789abcdef0123456789abcdef"
[System.IO.File]::WriteAllText(`$Ready, "ready")
Start-Sleep -Seconds 30
`$lock.Dispose()
"@
        Write-CgceContractTestUtf8 $holder $holderText
        $process = Start-Process -FilePath "$PSHOME\powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $holder, "-Module", $module, "-Root", $root, "-Ready", $ready) `
            -PassThru -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath $ready)
        $lockPath = Join-Path $root ".cgce-discovery.lock"
        Assert-CgceEqual 0 ([System.IO.FileInfo]$lockPath).Length
        Assert-CgceThrows "CGCE-OPS-CONTROL" {
            Enter-CgceExclusiveLock -ServerRoot $root -RunId "r-0123456789abcdef0123456789abcdef"
        }
        Assert-CgceEqual 0 ([System.IO.FileInfo]$lockPath).Length
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
