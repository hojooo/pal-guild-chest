Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Contract.psm1" -Force
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Files.psm1" -Force
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1" -Force

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
    $State.source_manifest_checksum = ("e" * 64)
    $State.inventory_checksums.original = ("1" * 64)
}

function Set-CgceContractSourceEvidence($State, [string]$SourcePhase) {
    Set-CgceContractCreatedEvidence $State
    if (@(
            "BACKUP_VERIFIED",
            "ORIGINAL_DEACTIVATED",
            "CLONE_ACTIVE",
            "PROBE_STAGED",
            "RUNNING",
            "CAPTURED"
        ) -contains $SourcePhase) {
        $State.inventory_checksums.backup = ("2" * 64)
    }
    if (@(
            "CLONE_ACTIVE",
            "PROBE_STAGED",
            "RUNNING",
            "CAPTURED"
        ) -contains $SourcePhase) {
        $State.inventory_checksums.clone = ("3" * 64)
    }
    if (@(
            "PROBE_STAGED",
            "RUNNING",
            "CAPTURED"
        ) -contains $SourcePhase) {
        $State.probe_receipt_checksum = ("4" * 64)
    }
    if ($SourcePhase -ceq "CAPTURED") {
        $State.process_launch_receipt_checksum = ("5" * 64)
    }
    if ($SourcePhase -ceq "CAPTURED") {
        $State.process_result_receipt_checksum = ("6" * 64)
        $State.capture_inventory_checksum = ("7" * 64)
    }
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
    foreach ($suffix in @("`n", "`r`n")) {
        Assert-CgceEqual `
            $false `
            (Test-CgceRunId (
                "r-0123456789abcdef0123456789abcdef" + $suffix
            ))
    }
}

Invoke-CgceTest "contract scalar validators reject valid prefixes followed by line endings" {
    foreach ($suffix in @("`n", "`r`n")) {
        $root = New-CgceContractTestRoot
        try {
            $paths = New-CgceContractTestPaths $root
            Assert-CgceThrows "CGCE-OPS-ID" {
                New-CgceRunState `
                    -RunId "r-0123456789abcdef0123456789abcdef" `
                    -MaintenanceId (
                        "m-0123456789abcdef0123456789abcdef" + $suffix
                    ) `
                    -Paths $paths
            }

            New-Item -ItemType Directory -Path $paths.run_directory |
                Out-Null
            New-Item -ItemType Directory -Path $paths.server_root |
                Out-Null
            $controlPath = Join-Path $root "control.json"
            foreach ($case in @(
                [pscustomobject]@{
                    Code = "CGCE-OPS-ID"
                    Mutate = {
                        param($Value)
                        $Value.maintenance_id += $suffix
                    }
                },
                [pscustomobject]@{
                    Code = "CGCE-OPS-CONTROL"
                    Mutate = {
                        param($Value)
                        $Value.ue4ss_dll_sha256 += $suffix
                    }
                },
                [pscustomobject]@{
                    Code = "CGCE-OPS-CONTROL"
                    Mutate = {
                        param($Value)
                        $Value.verified_at_utc += $suffix
                    }
                }
            )) {
                $control = New-CgceContractTestControl
                $null = & $case.Mutate $control
                Write-CgceContractTestControl $controlPath $control
                Assert-CgceThrows $case.Code {
                    Assert-CgceControlEvidence `
                        -EvidencePath $controlPath `
                        -ExpectedFileChecksum (Get-CgceSha256 $controlPath) `
                        -ExpectedBundleChecksum ("a" * 64) `
                        -NowUtc ([DateTime]"2026-07-23T00:30:00Z")
                }
            }

            $state = New-CgceRunState `
                -RunId "r-0123456789abcdef0123456789abcdef" `
                -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
                -Paths $paths
            Set-CgceContractCreatedEvidence $state
            Write-CgceJsonAtomic $state $paths.genesis_state
            $state.outcome = "BLOCKED"
            $state.revision = 1
            $state.errors = [object[]]@(
                [pscustomobject][ordered]@{
                    code = "CGCE-OPS-BLOCKED" + $suffix
                    at_utc = "2026-07-23T00:00:00Z"
                }
            )
            Write-CgceJsonAtomic $state $paths.state
            Assert-CgceThrows "CGCE-OPS-JSON" {
                Read-CgceRunState $root $state.run_id
            }
            Assert-CgceThrows "CGCE-OPS-BLOCKED" {
                Block-CgceRunState `
                    -StatePath $paths.state `
                    -Code ("CGCE-OPS-BLOCKED" + $suffix)
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Invoke-CgceTest "rejects skipped phases" {
    $state = [pscustomobject]@{ phase = "CREATED"; outcome = "ACTIVE" }
    Assert-CgceThrows "CGCE-OPS-PHASE" {
        Set-CgceRunPhase -State $state -ExpectedPhase "BACKUP_VERIFIED" -NextPhase "CLONE_ACTIVE"
    }
}

Invoke-CgceTest "normal transition helper rejects fixed-purpose recovery edges" {
    foreach ($case in @(
        [pscustomobject]@{
            Source = "CAPTURED"
            Destination = "RESTORING"
        },
        [pscustomobject]@{
            Source = "RESTORING"
            Destination = "RESTORED"
        }
    )) {
        foreach ($outcome in @("ACTIVE", "BLOCKED")) {
            $state = [pscustomobject]@{
                phase = $case.Source
                outcome = $outcome
            }
            Assert-CgceThrows "CGCE-OPS-PHASE" {
                Set-CgceRunPhase `
                    -State $state `
                    -ExpectedPhase $case.Source `
                    -NextPhase $case.Destination
            }
        }
    }
}

Invoke-CgceTest "strict JSON preserves root kinds and exact string array shape" {
    $root = New-CgceContractTestRoot
    try {
        $objectPath = Join-Path $root "object.json"
        $objectArrayPath = Join-Path $root "object-array.json"
        $stringPath = Join-Path $root "string.json"
        Write-CgceContractTestUtf8 $objectPath "{}"
        Write-CgceContractTestUtf8 $objectArrayPath "[{}]"
        Write-CgceContractTestUtf8 $stringPath '"x"'

        Assert-CgceEqual 0 @((Read-CgceJsonObject $objectPath).PSObject.Properties).Count
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $objectArrayPath }
        Assert-CgceThrows "CGCE-OPS-JSON" { Read-CgceJsonObject $stringPath }
        foreach ($case in @(
            [pscustomobject]@{ Json = "[]"; Expected = @() },
            [pscustomobject]@{ Json = '["x"]'; Expected = @("x") },
            [pscustomobject]@{
                Json = '["one","two","three"]'
                Expected = @("one", "two", "three")
            }
        )) {
            $path = Join-Path `
                $root `
                ("string-array-" + [guid]::NewGuid().ToString("N") + ".json")
            Write-CgceContractTestUtf8 $path $case.Json
            $values = Read-CgceJsonStringArray $path
            Assert-CgceEqual $true ($values -is [string[]])
            Assert-CgceDeepEqual $case.Expected $values
        }
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
        $writer = Get-Command "Write-CgceJsonAtomic"
        Assert-CgceEqual `
            $false `
            $writer.Parameters.ContainsKey("ExpectedExistingSha256")
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

Invoke-CgceTest "private state CAS rejects raw objects and is not exported" {
    $root = New-CgceContractTestRoot
    try {
        $path = Join-Path $root "run-state.json"
        Write-CgceContractTestUtf8 $path '{"value":"old"}'
        $oldSha = Get-CgceSha256 $path
        Assert-CgceEqual `
            $null `
            (Get-Command `
                "Replace-CgceRunStateJson" `
                -ErrorAction SilentlyContinue)
        $module = Get-Module "CgceDiscovery.Contract"
        $message = & $module {
            param([string]$Path, [string]$ExpectedStateChecksum)
            try {
                Replace-CgceRunStateJson `
                    -Value ([pscustomobject]@{ value = "new" }) `
                    -Path $Path `
                    -ExpectedStateChecksum $ExpectedStateChecksum
                return ""
            } catch {
                return $_.Exception.Message
            }
        } $path $oldSha
        Assert-CgceEqual `
            $true `
            ([string]$message).StartsWith(
                "CGCE-OPS-JSON",
                [StringComparison]::Ordinal
            )
        Assert-CgceEqual "old" (Read-CgceJsonObject $path).value
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state CAS rejects existing temp and checksum drift without deleting destination" {
    $root = New-CgceContractTestRoot
    $module = $null
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
        $oldSha = Get-CgceSha256 $paths.state
        $candidate = Read-CgceJsonObject $paths.state
        $candidate.inventory_checksums.backup = ("2" * 64)
        $candidate = Set-CgceRunPhase `
            $candidate `
            "CREATED" `
            "BACKUP_VERIFIED"

        Write-CgceContractTestUtf8 ($paths.state + ".tmp") '{}'
        Assert-CgceThrows "CGCE-OPS-OUTPUT-EXISTS" {
            Write-CgceRunState $candidate $paths.state "CREATED"
        }
        Assert-CgceEqual $oldSha (Get-CgceSha256 $paths.state)
        Remove-Item -LiteralPath ($paths.state + ".tmp")

        $module = Get-Module "CgceDiscovery.Contract"
        & $module {
            $script:CgceTestStatePersistenceSeam = {
                param([string]$Phase, $Context)
                if ($Phase -ceq "before-state-replace") {
                    $text = [System.IO.File]::ReadAllText(
                        $Context.state_path
                    )
                    $encoding = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText(
                        $Context.state_path,
                        ($text + " "),
                        $encoding
                    )
                }
            }
        }
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceRunState $candidate $paths.state "CREATED"
        }
        & $module { $script:CgceTestStatePersistenceSeam = $null }
        $current = Read-CgceJsonObject $paths.state
        Assert-CgceEqual "CREATED" $current.phase
        Assert-CgceEqual 0 $current.revision
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath ($paths.state + ".tmp"))
    } finally {
        if ($null -ne $module) {
            & $module { $script:CgceTestStatePersistenceSeam = $null }
        }
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
        Assert-CgceEqual 25 @($state.PSObject.Properties).Count
        Assert-CgceEqual 41 @($state.paths.PSObject.Properties).Count
        Assert-CgceEqual 4 @($state.inventory_checksums.PSObject.Properties).Count
        Assert-CgceEqual $null $state.source_manifest_checksum
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

Invoke-CgceTest "committed run state requires immutable source manifest authority" {
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
        Assert-CgceEqual `
            ("e" * 64) `
            (Read-CgceRunState $root $state.run_id).source_manifest_checksum

        $missing = Read-CgceJsonObject $paths.state
        $missing.PSObject.Properties.Remove("source_manifest_checksum")
        Write-CgceContractTestUtf8 `
            $paths.state `
            ($missing | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-JSON" {
            Read-CgceRunState $root $state.run_id
        }

        foreach ($invalid in @(
            $null,
            ("E" * 64),
            (("e" * 64) + "`n"),
            (("e" * 64) + "`r`n")
        )) {
            $candidate = Read-CgceJsonObject $paths.genesis_state
            $candidate.source_manifest_checksum = $invalid
            Write-CgceContractTestUtf8 `
                $paths.state `
                ($candidate | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
                Read-CgceRunState $root $state.run_id
            }
        }

        $drift = Read-CgceJsonObject $paths.genesis_state
        $drift.source_manifest_checksum = ("f" * 64)
        Write-CgceContractTestUtf8 `
            $paths.state `
            ($drift | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Read-CgceRunState $root $state.run_id
        }

        Write-CgceContractTestUtf8 `
            $paths.state `
            ((Read-CgceJsonObject $paths.genesis_state) |
                ConvertTo-Json -Depth 12)
        $oldChecksum = Get-CgceSha256 $paths.state
        $transition = Read-CgceJsonObject $paths.state
        $transition.source_manifest_checksum = ("f" * 64)
        $transition.inventory_checksums.backup = ("2" * 64)
        $transition = Set-CgceRunPhase `
            $transition `
            "CREATED" `
            "BACKUP_VERIFIED"
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceRunState $transition $paths.state "CREATED"
        }
        Assert-CgceEqual $oldChecksum (Get-CgceSha256 $paths.state)
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

Invoke-CgceTest "recovery checkpoint validator accepts exact source profiles without persistence authority" {
    $sourcePhases = @(
        "CREATED",
        "BACKUP_VERIFIED",
        "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE",
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED"
    )
    foreach ($sourcePhase in $sourcePhases) {
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

            $restoring = Read-CgceJsonObject $paths.genesis_state
            Set-CgceContractSourceEvidence $restoring $sourcePhase
            $restoring.phase = "RESTORING"
            $restoring.revision = 7
            Write-CgceContractTestUtf8 `
                $paths.state `
                ($restoring | ConvertTo-Json -Depth 12)
            Assert-CgceEqual `
                "RESTORING" `
                (Read-CgceRunState $root $restoring.run_id).phase

            $restored = Read-CgceJsonObject $paths.state
            $restored.phase = "RESTORED"
            $restored.revision = 8
            $restored.inventory_checksums.restored = ("8" * 64)
            Write-CgceContractTestUtf8 `
                $paths.state `
                ($restored | ConvertTo-Json -Depth 12)
            Assert-CgceEqual `
                "RESTORED" `
                (Read-CgceRunState $root $restored.run_id).phase
        } catch {
            throw "CGCE-TEST source phase ${sourcePhase}: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    $invalidMutations = @(
        {
            param($State)
            $State.inventory_checksums.clone = ("3" * 64)
        },
        {
            param($State)
            $State.inventory_checksums.backup = ("2" * 64)
            $State.probe_receipt_checksum = ("4" * 64)
        },
        {
            param($State)
            $State.inventory_checksums.backup = ("2" * 64)
            $State.inventory_checksums.clone = ("3" * 64)
            $State.process_launch_receipt_checksum = ("5" * 64)
        },
        {
            param($State)
            $State.inventory_checksums.backup = ("2" * 64)
            $State.inventory_checksums.clone = ("3" * 64)
            $State.probe_receipt_checksum = ("4" * 64)
            $State.process_result_receipt_checksum = ("6" * 64)
        }
    )
    foreach ($mutation in $invalidMutations) {
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
            $invalid = Read-CgceJsonObject $paths.genesis_state
            $invalid.phase = "RESTORING"
            $invalid.revision = 7
            $null = & $mutation $invalid
            Write-CgceContractTestUtf8 `
                $paths.state `
                ($invalid | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-PHASE" {
                Read-CgceRunState $root $invalid.run_id
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Invoke-CgceTest "normal state writer rejects fixed-purpose recovery edges for active and blocked authority" {
    foreach ($case in @(
        [pscustomobject]@{
            Source = "CAPTURED"
            Destination = "RESTORING"
            Revision = 6
        },
        [pscustomobject]@{
            Source = "RESTORING"
            Destination = "RESTORED"
            Revision = 7
        }
    )) {
        foreach ($outcome in @("ACTIVE", "BLOCKED")) {
            $root = New-CgceContractTestRoot
            try {
                $paths = New-CgceContractTestPaths $root
                New-Item `
                    -ItemType Directory `
                    -Path $paths.run_directory |
                    Out-Null
                New-Item `
                    -ItemType Directory `
                    -Path $paths.server_root |
                    Out-Null
                $genesis = New-CgceRunState `
                    -RunId "r-0123456789abcdef0123456789abcdef" `
                    -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
                    -Paths $paths
                Set-CgceContractCreatedEvidence $genesis
                Write-CgceJsonAtomic $genesis $paths.genesis_state

                $source = Read-CgceJsonObject $paths.genesis_state
                Set-CgceContractSourceEvidence $source "CAPTURED"
                $source.phase = $case.Source
                $source.revision = $case.Revision
                $source.outcome = $outcome
                if ($outcome -ceq "BLOCKED") {
                    $source.errors = @(
                        [pscustomobject][ordered]@{
                            code = "CGCE-OPS-BLOCKED"
                            at_utc = "2026-07-23T00:00:00Z"
                        }
                    )
                }
                Write-CgceJsonAtomic $source $paths.state
                $sourceChecksum = Get-CgceSha256 $paths.state

                $candidate = Read-CgceJsonObject $paths.state
                $candidate.phase = $case.Destination
                if ($case.Destination -ceq "RESTORED") {
                    $candidate.inventory_checksums.restored = ("8" * 64)
                }
                Assert-CgceThrows "CGCE-OPS-PHASE" {
                    Write-CgceRunState `
                        -State $candidate `
                        -StatePath $paths.state `
                        -ExpectedPhase $case.Source
                }
                Assert-CgceEqual `
                    $sourceChecksum `
                    (Get-CgceSha256 $paths.state)
                $current = Read-CgceJsonObject $paths.state
                Assert-CgceEqual $case.Source $current.phase
                Assert-CgceEqual $outcome $current.outcome
                Assert-CgceEqual $case.Revision $current.revision
            } catch {
                throw (
                    "CGCE-TEST $($case.Source) ${outcome}: " +
                    $_.Exception.Message
                )
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "normal block paths reject RESTORING but retain adjacent checkpoint blocking" {
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
        Write-CgceJsonAtomic $genesis $paths.state
        Write-CgceActiveRunMarker `
            -State $genesis `
            -GenesisStateChecksum (Get-CgceSha256 $paths.genesis_state) `
            -Path $paths.active_run_marker

        $restoring = Read-CgceJsonObject $paths.genesis_state
        Set-CgceContractSourceEvidence $restoring "CAPTURED"
        $restoring.phase = "RESTORING"
        $restoring.revision = 7
        Write-CgceContractTestUtf8 `
            $paths.state `
            ($restoring | ConvertTo-Json -Depth 12)
        $restoringChecksum = Get-CgceSha256 $paths.state
        $blockedCandidate = Read-CgceJsonObject $paths.state
        $blockedCandidate.outcome = "BLOCKED"
        $blockedCandidate.errors = @(
            [pscustomobject][ordered]@{
                code = "CGCE-OPS-BLOCKED"
                at_utc = "2026-07-23T00:00:00Z"
            }
        )
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Write-CgceRunState `
                -State $blockedCandidate `
                -StatePath $paths.state `
                -ExpectedPhase "RESTORING"
        }
        Assert-CgceThrows "CGCE-OPS-PHASE" {
            Block-CgceRunState `
                -StatePath $paths.state `
                -Code "CGCE-OPS-BLOCKED"
        }
        Assert-CgceEqual $restoringChecksum (Get-CgceSha256 $paths.state)

        foreach ($phase in @("CAPTURED", "RESTORED")) {
            $source = Read-CgceJsonObject $paths.genesis_state
            Set-CgceContractSourceEvidence $source "CAPTURED"
            $source.phase = $phase
            $source.revision = if ($phase -ceq "CAPTURED") { 6 } else { 8 }
            if ($phase -ceq "RESTORED") {
                $source.inventory_checksums.restored = ("8" * 64)
            }
            Write-CgceContractTestUtf8 `
                $paths.state `
                ($source | ConvertTo-Json -Depth 12)
            $blocked = Block-CgceRunState `
                -StatePath $paths.state `
                -Code "CGCE-OPS-BLOCKED"
            Assert-CgceEqual $phase $blocked.phase
            Assert-CgceEqual "BLOCKED" $blocked.outcome
            Assert-CgceEqual 1 @($blocked.errors).Count
        }
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
        Write-CgceJsonAtomic $genesis $paths.state
        Write-CgceActiveRunMarker `
            -State $genesis `
            -GenesisStateChecksum (Get-CgceSha256 $paths.genesis_state) `
            -Path $paths.active_run_marker
        $running = Read-CgceJsonObject $paths.genesis_state
        $running.phase = "RUNNING"
        $running.revision = 5
        $running.inventory_checksums.backup = ("2" * 64)
        $running.inventory_checksums.clone = ("3" * 64)
        $running.probe_receipt_checksum = ("4" * 64)
        Write-CgceContractTestUtf8 `
            -Path $paths.state `
            -Text ($running | ConvertTo-Json -Depth 12)

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

Invoke-CgceTest "active marker accepts only byte-identical pristine CREATED genesis" {
    $mutations = @(
        {
            param($State)
            $State.phase = "BACKUP_VERIFIED"
            $State.revision = 1
            $State.inventory_checksums.backup = ("2" * 64)
        },
        {
            param($State)
            $State.revision = 1
        },
        {
            param($State)
            $State.outcome = "BLOCKED"
            $State.errors = @(
                [pscustomobject]@{
                    code = "CGCE-OPS-BLOCKED"
                    at_utc = "2026-07-23T00:00:00Z"
                }
            )
        },
        {
            param($State)
            $State.errors = @(
                [pscustomobject]@{
                    code = "CGCE-OPS-BLOCKED"
                    at_utc = "2026-07-23T00:00:00Z"
                }
            )
        },
        {
            param($State)
            $State.inventory_checksums.backup = ("2" * 64)
        },
        {
            param($State)
            $State.probe_receipt_checksum = ("4" * 64)
        }
    )
    foreach ($mutation in $mutations) {
        $root = New-CgceContractTestRoot
        try {
            $fixture = New-CgceContractTestMarkerFixture $root
            Remove-Item -LiteralPath $fixture.paths.active_run_marker
            $candidate = Read-CgceJsonObject $fixture.paths.genesis_state
            $null = & $mutation $candidate
            Write-CgceContractTestUtf8 `
                $fixture.paths.genesis_state `
                ($candidate | ConvertTo-Json -Depth 12)
            Write-CgceContractTestUtf8 `
                $fixture.paths.state `
                ($candidate | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-PHASE" {
                Write-CgceActiveRunMarker `
                    -State $candidate `
                    -GenesisStateChecksum (
                        Get-CgceSha256 $fixture.paths.genesis_state
                    ) `
                    -Path $fixture.paths.active_run_marker
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    $root = New-CgceContractTestRoot
    try {
        $fixture = New-CgceContractTestMarkerFixture $root
        Remove-Item -LiteralPath $fixture.paths.active_run_marker
        $current = Read-CgceJsonObject $fixture.paths.state
        Write-CgceContractTestUtf8 `
            $fixture.paths.state `
            (($current | ConvertTo-Json -Depth 12) + " ")
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Write-CgceActiveRunMarker `
                -State $current `
                -GenesisStateChecksum (
                    Get-CgceSha256 $fixture.paths.genesis_state
                ) `
                -Path $fixture.paths.active_run_marker
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
            "tests/windows/Run-CgceDiscoverySmokeTests.ps1",
            "tests/windows/Run-CgceDiscoveryTests.ps1",
            "tests/windows/Runtime.Tests.ps1",
            "tests/windows/Smoke.Tests.ps1",
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
        $manifestChecksum = Get-CgceSha256 $manifest
        Assert-CgceHandoffSource `
            -HandoffRoot $root `
            -ManifestPath $manifest `
            -ExpectedManifestChecksum $manifestChecksum

        $records[1] = ("0" * 64) + "  " + $paths[1]
        Write-CgceContractTestUtf8 $manifest (($records -join "`n") + "`n")
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceHandoffSource `
                -HandoffRoot $root `
                -ManifestPath $manifest `
                -ExpectedManifestChecksum $manifestChecksum
        }

        Write-CgceContractTestUtf8 `
            (Join-Path $root ($paths[1] -replace '/', '\')) `
            "re-signed payload"
        $records[1] = (
            Get-CgceSha256 (
                Join-Path $root ($paths[1] -replace '/', '\')
            )
        ) + "  " + $paths[1]
        Write-CgceContractTestUtf8 $manifest (($records -join "`n") + "`n")
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Assert-CgceHandoffSource `
                -HandoffRoot $root `
                -ManifestPath $manifest `
                -ExpectedManifestChecksum $manifestChecksum
        }
        Assert-CgceHandoffSource `
            -HandoffRoot $root `
            -ManifestPath $manifest `
            -ExpectedManifestChecksum (Get-CgceSha256 $manifest)
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

function ConvertTo-CgceContractTestJson($Value) {
    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Get-CgceContractErrorCode([scriptblock]$Body) {
    try {
        $null = & $Body
        return ""
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -cnotmatch '^(CGCE-OPS-[A-Z0-9-]+)(?: |\z)') {
            throw "CGCE-TEST unstable error message: $message"
        }
        return $Matches[1]
    }
}

function Get-CgceContractFixtureSnapshot($Fixture) {
    $records = New-Object 'Collections.Generic.List[string]'
    foreach ($item in @(
            Get-ChildItem -LiteralPath $Fixture.Root -Recurse -Force |
                Sort-Object -Property FullName
        )) {
        $relative = $item.FullName.Substring($Fixture.Root.Length)
        if ($relative.StartsWith("\")) {
            $relative = $relative.Substring(1)
        }
        if ($item.PSIsContainer) {
            $null = $records.Add("D|$relative")
        } else {
            $null = $records.Add(
                "F|$relative|$($item.Length)|$(Get-CgceSha256 $item.FullName)"
            )
        }
    }
    return [string]::Join("`n", [string[]]$records.ToArray())
}

function Assert-CgceRecoveryStateMatchesSource(
    $Source,
    $Actual,
    [string]$ExpectedPhase,
    [int64]$ExpectedRevision,
    [string]$ExpectedOutcome,
    [bool]$AppendError = $false,
    [string]$AppendedCode = "",
    [string]$RestoredChecksum = ""
) {
    Assert-CgceDeepEqual `
        ([string]::Join(",", @($Source.PSObject.Properties.Name))) `
        ([string]::Join(",", @($Actual.PSObject.Properties.Name)))
    foreach ($property in @($Source.PSObject.Properties.Name)) {
        switch ($property) {
            "phase" { Assert-CgceDeepEqual $ExpectedPhase $Actual.phase }
            "revision" { Assert-CgceDeepEqual $ExpectedRevision ([int64]$Actual.revision) }
            "outcome" { Assert-CgceDeepEqual $ExpectedOutcome $Actual.outcome }
            "updated_at_utc" {
                Assert-CgceEqual $true `
                    ([string]$Actual.updated_at_utc -cmatch `
                        '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')
            }
            "errors" {
                $sourceErrors = @($Source.errors)
                $actualErrors = @($Actual.errors)
                $expectedCount = $sourceErrors.Count
                if ($AppendError) { $expectedCount += 1 }
                Assert-CgceDeepEqual $expectedCount $actualErrors.Count
                for ($index = 0; $index -lt $sourceErrors.Count; $index += 1) {
                    Assert-CgceDeepEqual `
                        (ConvertTo-CgceContractTestJson $sourceErrors[$index]) `
                        (ConvertTo-CgceContractTestJson $actualErrors[$index])
                }
                if ($AppendError) {
                    $appended = $actualErrors[-1]
                    Assert-CgceDeepEqual "code,at_utc" `
                        ([string]::Join(",", @($appended.PSObject.Properties.Name)))
                    Assert-CgceDeepEqual $AppendedCode $appended.code
                    Assert-CgceEqual $true `
                        ([string]$appended.at_utc -cmatch `
                            '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')
                }
            }
            "inventory_checksums" {
                Assert-CgceDeepEqual `
                    ([string]::Join(",", @($Source.inventory_checksums.PSObject.Properties.Name))) `
                    ([string]::Join(",", @($Actual.inventory_checksums.PSObject.Properties.Name)))
                foreach ($name in @("original", "backup", "clone")) {
                    Assert-CgceDeepEqual `
                        (ConvertTo-CgceContractTestJson $Source.inventory_checksums.$name) `
                        (ConvertTo-CgceContractTestJson $Actual.inventory_checksums.$name)
                }
                $expectedRestored = if ([string]::IsNullOrEmpty($RestoredChecksum)) {
                    $Source.inventory_checksums.restored
                } else {
                    $RestoredChecksum
                }
                Assert-CgceDeepEqual `
                    (ConvertTo-CgceContractTestJson $expectedRestored) `
                    (ConvertTo-CgceContractTestJson $Actual.inventory_checksums.restored)
            }
            default {
                Assert-CgceDeepEqual `
                    (ConvertTo-CgceContractTestJson $Source.$property) `
                    (ConvertTo-CgceContractTestJson $Actual.$property)
            }
        }
    }
}

function New-CgceRecoveryArtifactState([string]$TreeSha256, [bool]$Present) {
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $Present
        length = $null
        sha256 = $null
        tree_sha256 = if ($Present) { $TreeSha256 } else { $null }
    }
}

function Get-CgceContractTestPhaseRevision([string]$Phase) {
    return [Array]::IndexOf(@(
        "CREATED", "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED"
    ), $Phase)
}

function Get-CgceContractTestCase([string]$Phase) {
    if ($Phase -ceq "CREATED" -or $Phase -ceq "BACKUP_VERIFIED") {
        return "UNCHANGED_ORIGINAL"
    }
    if ($Phase -ceq "ORIGINAL_DEACTIVATED") {
        return "NO_ACTIVE_AND_INACTIVE_ORIGINAL"
    }
    return "CLONE_AND_INACTIVE_ORIGINAL"
}

function New-CgceContractRecoverySteps($Paths, [string]$SelectedCase, $Original, $Clone, $Absent) {
    if ($SelectedCase -ceq "UNCHANGED_ORIGINAL") {
        return @(
            [pscustomobject][ordered]@{
                sequence = 10; step = "QUARANTINE_CLONE"; operation = "VERIFY_RESTORED"
                source_path = $Paths.active_saved; destination_path = $Paths.quarantined_clone
                before_state = [pscustomobject][ordered]@{ source = $Original; destination = $Absent }
                after_state = [pscustomobject][ordered]@{ source = $Original; destination = $Absent }
            },
            [pscustomobject][ordered]@{
                sequence = 20; step = "RESTORE_ORIGINAL"; operation = "VERIFY_RESTORED"
                source_path = $Paths.inactive_original; destination_path = $Paths.active_saved
                before_state = [pscustomobject][ordered]@{ source = $Absent; destination = $Original }
                after_state = [pscustomobject][ordered]@{ source = $Absent; destination = $Original }
            }
        )
    }
    $firstOperation = if ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        "VERIFY_ABSENT"
    } else {
        "MOVE_DIRECTORY"
    }
    $firstSource = if ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        $Absent
    } else {
        $Clone
    }
    return @(
        [pscustomobject][ordered]@{
            sequence = 10; step = "QUARANTINE_CLONE"; operation = $firstOperation
            source_path = $Paths.active_saved; destination_path = $Paths.quarantined_clone
            before_state = [pscustomobject][ordered]@{ source = $firstSource; destination = $Absent }
            after_state = [pscustomobject][ordered]@{ source = $Absent; destination = $firstSource }
        },
        [pscustomobject][ordered]@{
            sequence = 20; step = "RESTORE_ORIGINAL"; operation = "MOVE_DIRECTORY"
            source_path = $Paths.inactive_original; destination_path = $Paths.active_saved
            before_state = [pscustomobject][ordered]@{ source = $Original; destination = $Absent }
            after_state = [pscustomobject][ordered]@{ source = $Absent; destination = $Original }
        }
    )
}

function New-CgceRecoveryContractFixture(
    [string]$SourcePhase = "CREATED",
    [string]$Outcome = "ACTIVE",
    [string]$SelectedCase = "",
    [bool]$ManualStateError = $false,
    [int]$ListenerPort = 0
) {
    $root = New-CgceContractTestRoot
    $paths = New-CgceContractTestPaths $root
    foreach ($directory in @(
            $paths.run_directory, $paths.server_root,
            (Split-Path -Parent $paths.original_inventory),
            $paths.restore_receipts, $paths.process_receipts,
            $paths.probe_receipts
        )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($SelectedCase)) {
        $SelectedCase = Get-CgceContractTestCase $SourcePhase
    }
    if ($ListenerPort -eq 0) {
        $reservation = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $reservation.Start()
        $ListenerPort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
        $reservation.Stop()
    }
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $paths.active_saved) `
        -Force | Out-Null

    $originalSource = Join-Path $root "original-source"
    New-Item -ItemType Directory -Path $originalSource | Out-Null
    Write-CgceContractTestUtf8 (Join-Path $originalSource "World.sav") "original-world"
    $originalEntries = @(Get-CgceTreeInventory -Root $originalSource)
    $originalTree = Get-CgceInventoryTreeSha256 -Entries $originalEntries
    $originalState = New-CgceRecoveryArtifactState $originalTree $true
    $absentState = New-CgceRecoveryArtifactState "" $false

    $cloneSource = Join-Path $root "clone-source"
    New-Item -ItemType Directory -Path $cloneSource | Out-Null
    Write-CgceContractTestUtf8 (Join-Path $cloneSource "World.sav") "test-clone"
    $cloneEntries = @(Get-CgceTreeInventory -Root $cloneSource)
    $cloneTree = Get-CgceInventoryTreeSha256 -Entries $cloneEntries
    $cloneState = New-CgceRecoveryArtifactState $cloneTree $true

    if ($SelectedCase -ceq "UNCHANGED_ORIGINAL") {
        $null = Copy-CgceTreeVerified $originalSource $paths.active_saved
    } elseif ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        $null = Copy-CgceTreeVerified $originalSource $paths.inactive_original
    } else {
        $null = Copy-CgceTreeVerified $cloneSource $paths.active_saved
        $null = Copy-CgceTreeVerified $originalSource $paths.inactive_original
    }

    $genesis = New-CgceRunState `
        -RunId "r-0123456789abcdef0123456789abcdef" `
        -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
        -Paths $paths
    $genesis.bundle_checksum = ("a" * 64)
    $genesis.control_evidence_checksum = ("b" * 64)
    $genesis.source_manifest_checksum = ("c" * 64)
    $genesis.palserver_executable = (Join-Path $paths.server_root "PalServer.exe")
    $genesis.palserver_executable_checksum = ("d" * 64)
    $genesis.ue4ss_version = "3.0.1"
    $genesis.server_process_paths = @($genesis.palserver_executable)
    $genesis.ue4ss_dll_checksum = ("e" * 64)
    $genesis.listener_ports = @($ListenerPort)
    $genesis.inventory_checksums.original = Write-CgceInventory `
        -Entries $originalEntries -Path $paths.original_inventory -Kind "original"
    Write-CgceJsonAtomic $genesis $paths.genesis_state
    Write-CgceJsonAtomic $genesis $paths.state
    Write-CgceActiveRunMarker `
        -State $genesis `
        -GenesisStateChecksum (Get-CgceSha256 $paths.genesis_state) `
        -Path $paths.active_run_marker

    $source = Read-CgceJsonObject $paths.genesis_state
    $fixtureCreatedAt = [DateTime]::ParseExact(
        $source.created_at_utc,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
    $source.phase = $SourcePhase
    $source.revision = Get-CgceContractTestPhaseRevision $SourcePhase
    if ($Outcome -ceq "BLOCKED") {
        $source.revision = [int64]$source.revision + 1
    }
    $source.outcome = $Outcome
    if ($Outcome -ceq "BLOCKED") {
        $source.errors = @([pscustomobject][ordered]@{
            code = if ($ManualStateError) { "CGCE-OPS-MANUAL-RECOVERY" } else { "CGCE-OPS-PRIOR-FAILURE" }
            at_utc = $fixtureCreatedAt.ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        })
    }
    $requiresBackup = @(
        "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED", "CLONE_ACTIVE",
        "PROBE_STAGED", "RUNNING", "CAPTURED"
    ) -contains $SourcePhase
    if ($requiresBackup) {
        $source.inventory_checksums.backup = Write-CgceInventory `
            -Entries $originalEntries -Path $paths.backup_inventory -Kind "backup"
    }
    if (@("CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED") -contains $SourcePhase) {
        $source.inventory_checksums.clone = Write-CgceInventory `
            -Entries $cloneEntries -Path $paths.clone_inventory -Kind "clone"
    }
    if (@("PROBE_STAGED", "RUNNING", "CAPTURED") -contains $SourcePhase) {
        $source.probe_receipt_checksum = ("4" * 64)
    }
    if ($SourcePhase -ceq "CAPTURED") {
        $source.process_launch_receipt_checksum = ("5" * 64)
        $source.process_result_receipt_checksum = ("6" * 64)
        $source.capture_inventory_checksum = ("7" * 64)
    }
    Write-CgceContractTestUtf8 $paths.state (ConvertTo-CgceContractTestJson $source)

    $steps = @(New-CgceContractRecoverySteps `
        $paths $SelectedCase $originalState $cloneState $absentState)
    $intent = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_restore_intent"
        run_id = $source.run_id; sequence = 0
        created_at_utc = $fixtureCreatedAt.AddSeconds(1).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        source_state_sha256 = (Get-CgceSha256 $paths.state)
        source_phase = $source.phase; source_outcome = $source.outcome
        source_revision = $source.revision
        source_updated_at_utc = $source.updated_at_utc
        source_errors = $source.errors
        genesis_state_sha256 = (Get-CgceSha256 $paths.genesis_state)
        original_inventory_sha256 = $source.inventory_checksums.original
        original_tree_sha256 = $originalTree
        selected_case = $SelectedCase
        paths = [pscustomobject][ordered]@{
            active_saved = $paths.active_saved
            inactive_original = $paths.inactive_original
            quarantined_clone = $paths.quarantined_clone
            original_inventory = $paths.original_inventory
            restored_inventory = $paths.restored_inventory
            restore_receipts = $paths.restore_receipts
            probe_restore_final_receipt = (Join-Path $paths.probe_receipts "restore\999-probe-restore-final.json")
        }
        steps = $steps
    }
    $intentPath = Join-Path $paths.restore_receipts "000-restore-intent.json"
    Write-CgceJsonAtomic $intent $intentPath
    return [pscustomobject]@{
        Root = $root; Paths = $paths; Genesis = $genesis; Source = $source
        Intent = $intent; IntentPath = $intentPath
        OriginalEntries = $originalEntries; OriginalTree = $originalTree
        CreatedAt = $fixtureCreatedAt
    }
}

function Set-CgceContractFixtureRestoring($Fixture) {
    $state = Read-CgceJsonObject $Fixture.Paths.state
    $state.phase = "RESTORING"
    $state.revision = [int64]$Fixture.Intent.source_revision + 1
    $state.updated_at_utc = $Fixture.CreatedAt.AddSeconds(2).ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    Write-CgceContractTestUtf8 $Fixture.Paths.state (ConvertTo-CgceContractTestJson $state)
}

function Write-CgceContractRecoveryJournal($Fixture) {
    if (-not (Test-Path -LiteralPath $Fixture.Paths.restored_inventory)) {
        $null = Write-CgceInventory `
            -Entries $Fixture.OriginalEntries `
            -Path $Fixture.Paths.restored_inventory `
            -Kind "restored"
    }
    $previous = Get-CgceSha256 $Fixture.IntentPath
    $bindings = New-Object 'Collections.Generic.List[object]'
    foreach ($index in 0, 1) {
        $step = @($Fixture.Intent.steps)[$index]
        $sequence = [int]$step.sequence
        $leaf = if ($sequence -eq 10) {
            "010-quarantine-clone.json"
        } else {
            "020-restore-original.json"
        }
        $path = Join-Path $Fixture.Paths.restore_receipts $leaf
        $receipt = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_restore_operation"
            run_id = $Fixture.Source.run_id
            sequence = $sequence
            step = $step.step; operation = $step.operation
            source_path = $step.source_path; destination_path = $step.destination_path
            before_state = $step.before_state; after_state = $step.after_state
            previous_receipt_sha256 = $previous
            completed_at_utc = $Fixture.CreatedAt.AddSeconds(
                $index + 3
            ).ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        Write-CgceJsonAtomic $receipt $path
        $previous = Get-CgceSha256 $path
        $null = $bindings.Add([pscustomobject][ordered]@{
            sequence = $sequence; path = $path; sha256 = $previous
        })
    }
    $restoredSha = Get-CgceSha256 $Fixture.Paths.restored_inventory
    $probeBinding = $null
    if ($null -ne $Fixture.Source.probe_receipt_checksum) {
        $probePath = $Fixture.Intent.paths.probe_restore_final_receipt
        $probeBinding = [pscustomobject][ordered]@{
            path = $probePath
            sha256 = (Get-CgceSha256 $probePath)
        }
    }
    $final = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_restore_final"
        run_id = $Fixture.Source.run_id; sequence = 999
        restore_intent_sha256 = (Get-CgceSha256 $Fixture.IntentPath)
        previous_receipt_sha256 = $previous
        operation_receipts = [object[]]$bindings.ToArray()
        probe_restore_final_receipt = $probeBinding
        original_inventory = [pscustomobject][ordered]@{
            path = $Fixture.Paths.original_inventory
            sha256 = $Fixture.Source.inventory_checksums.original
            tree_sha256 = $Fixture.OriginalTree
        }
        restored_inventory = [pscustomobject][ordered]@{
            path = $Fixture.Paths.restored_inventory
            sha256 = $restoredSha; tree_sha256 = $Fixture.OriginalTree
        }
        completed_at_utc = $Fixture.CreatedAt.AddSeconds(5).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    Write-CgceJsonAtomic $final (Join-Path $Fixture.Paths.restore_receipts "999-restore-final.json")
}

function Initialize-CgceContractProbeRecoveryAuthority($Fixture) {
    Remove-Item -LiteralPath $Fixture.IntentPath
    Remove-Item -LiteralPath $Fixture.Paths.active_saved -Recurse -Force
    Remove-Item -LiteralPath $Fixture.Paths.clone_inventory
    $null = Copy-CgceTreeVerified `
        -Source $Fixture.Paths.inactive_original `
        -Destination $Fixture.Paths.active_saved
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $Fixture.Paths.backup_saved) `
        -Force | Out-Null
    $null = Copy-CgceTreeVerified `
        -Source $Fixture.Paths.inactive_original `
        -Destination $Fixture.Paths.backup_saved
    $cloneEntries = @(Get-CgceTreeInventory -Root $Fixture.Paths.active_saved)
    $Fixture.Source.inventory_checksums.clone = Write-CgceInventory `
        -Entries $cloneEntries `
        -Path $Fixture.Paths.clone_inventory `
        -Kind "clone"

    foreach ($directory in @(
            (Split-Path -Parent $Fixture.Paths.mods_txt),
            $Fixture.Paths.capture,
            (Join-Path $Fixture.Paths.run_directory "before")
        )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Write-CgceContractTestUtf8 $Fixture.Paths.ue4ss_dll "synthetic"
    Write-CgceContractTestUtf8 `
        $Fixture.Paths.mods_txt `
        "BPModLoaderMod : 1`r`n; preserved comment`r`n"
    Write-CgceContractTestUtf8 $Fixture.Paths.object_dump "old objects"
    New-Item -ItemType Directory -Path $Fixture.Paths.cxx_header_dump | Out-Null
    Write-CgceContractTestUtf8 `
        (Join-Path $Fixture.Paths.cxx_header_dump "Old.hpp") `
        "old headers"
    Write-CgceContractTestUtf8 $Fixture.Paths.ue4ss_log "old log"

    $probeSource = (
        Resolve-Path "$PSScriptRoot\..\..\tools\windows-discovery\probe\CGCEDiscoveryInventory"
    ).Path
    $stage = Enable-CgceInventoryProbe `
        -Ue4ssRoot $Fixture.Paths.ue4ss_root `
        -ProbeSource $probeSource `
        -RunDirectory $Fixture.Paths.run_directory `
        -RunId $Fixture.Source.run_id `
        -Paths $Fixture.Paths

    $Fixture.Source.probe_receipt_checksum = $stage.checksum
    Write-CgceContractTestUtf8 `
        $Fixture.Paths.state `
        (ConvertTo-CgceContractTestJson $Fixture.Source)
    $original = New-CgceRecoveryArtifactState $Fixture.OriginalTree $true
    $absent = New-CgceRecoveryArtifactState "" $false
    $Fixture.Intent.steps = @(New-CgceContractRecoverySteps `
        $Fixture.Paths `
        $Fixture.Intent.selected_case `
        $original `
        $original `
        $absent)
    $Fixture.Intent.source_state_sha256 = Get-CgceSha256 $Fixture.Paths.state
    $Fixture.Intent.source_phase = $Fixture.Source.phase
    $Fixture.Intent.source_outcome = $Fixture.Source.outcome
    $Fixture.Intent.source_revision = $Fixture.Source.revision
    $Fixture.Intent.source_updated_at_utc = $Fixture.Source.updated_at_utc
    $Fixture.Intent.source_errors = $Fixture.Source.errors
    Write-CgceJsonAtomic $Fixture.Intent $Fixture.IntentPath
    $null = Write-CgceRecoveryRunState `
        $Fixture.Paths.state `
        $Fixture.IntentPath
    Restore-CgceInventoryProbe `
        -Paths $Fixture.Paths `
        -RunDirectory $Fixture.Paths.run_directory `
        -RunId $Fixture.Source.run_id `
        -ExpectedFinalReceiptChecksum $stage.checksum
    $probeFinal = $Fixture.Intent.paths.probe_restore_final_receipt
    return [pscustomobject]@{
        StageChecksum = $stage.checksum
        RestoreFinalPath = $probeFinal
        RestoreFinalChecksum = (Get-CgceSha256 $probeFinal)
    }
}

function Complete-CgceContractRecoveryFilesystem($Fixture) {
    if ($Fixture.Intent.selected_case -ceq "CLONE_AND_INACTIVE_ORIGINAL") {
        Move-CgceDirectoryNoOverwrite `
            $Fixture.Paths.active_saved `
            $Fixture.Paths.quarantined_clone
        Move-CgceDirectoryNoOverwrite `
            $Fixture.Paths.inactive_original `
            $Fixture.Paths.active_saved
    } elseif ($Fixture.Intent.selected_case -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        Move-CgceDirectoryNoOverwrite `
            $Fixture.Paths.inactive_original `
            $Fixture.Paths.active_saved
    }
}

function Add-CgceContractManualSentinel($Fixture) {
    $runtime = Get-Module "CgceDiscovery.Runtime"
    $allowed = [string[]]@($Fixture.Source.server_process_paths)
    $pathsDigest = & $runtime {
        param($Values)
        Get-CgceFramedStringArraySha256 -Domain "CGCE-PATHS-1" -Values $Values
    } $allowed
    $launch = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_process_launch"
        run_id = $Fixture.Source.run_id; sequence = 0
        created_at_utc = "2026-07-24T00:00:00Z"
        executable_path = $allowed[0]; executable_sha256 = ("a" * 64)
        working_directory = (Split-Path -Parent $allowed[0])
        allowed_executable_path_count = $allowed.Count
        allowed_executable_paths_sha256 = $pathsDigest
        argument_count = 0; arguments_sha256 = ("b" * 64)
        timeout_seconds = 300; control_valid_until_utc = "2026-07-24T01:00:00Z"
        previous_receipt_sha256 = $null
    }
    $launchPath = Join-Path $Fixture.Paths.process_receipts "000-launch.json"
    Write-CgceJsonAtomic $launch $launchPath
    $previous = Get-CgceSha256 $launchPath
    $barrier = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_process_manual_recovery"
        run_id = $Fixture.Source.run_id
        reason = "IDENTITY_UNREADABLE"
        pid = 420043; parent_pid = 0
        observed_at_utc = "2026-07-24T00:00:01Z"
        previous_receipt_sha256 = $previous
    }
    $path = Join-Path $Fixture.Paths.process_receipts "manual-recovery-required.json"
    Write-CgceJsonAtomic $barrier $path
    $null = & $runtime {
        param($BarrierPath, $RunId, $Previous)
        Read-CgceManualRecoveryBarrier `
            -Path $BarrierPath -RunId $RunId `
            -PreviousChecksum $Previous -PidReceipts @()
    } $path $Fixture.Source.run_id $previous
    Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
        Assert-CgceNoServerActivity `
            -ExecutablePaths $Fixture.Source.server_process_paths `
            -Ports $Fixture.Source.listener_ports `
            -ReceiptRoot $Fixture.Paths.process_receipts
    }
}

function Set-CgceContractRuntimeSnapshot($Snapshot) {
    $runtime = Get-Module "CgceDiscovery.Runtime"
    & $runtime {
        param($Value)
        if ($null -eq $Value) {
            $script:CgceTestActivitySnapshotSeam = $null
        } else {
            $captured = $Value
            $script:CgceTestActivitySnapshotSeam = {
                return $captured
            }.GetNewClosure()
        }
    } $Snapshot
}

function New-CgceContractRuntimeSnapshot([object[]]$Processes, [object[]]$Tcp) {
    return [pscustomobject]@{
        cim_available = $true; tcp_available = $true; udp_available = $true
        processes = [object[]]$Processes; tcp = [object[]]$Tcp; udp = [object[]]@()
    }
}

function Add-CgceContractUnlistedPidReceipts($Fixture, $ProcessRecord) {
    $runtime = Get-Module "CgceDiscovery.Runtime"
    $allowed = [string[]]@($Fixture.Source.server_process_paths)
    $pathsDigest = & $runtime {
        param($Values)
        Get-CgceFramedStringArraySha256 -Domain "CGCE-PATHS-1" -Values $Values
    } $allowed
    $launch = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_process_launch"
        run_id = $Fixture.Source.run_id; sequence = 0
        created_at_utc = "2026-07-24T00:00:00Z"
        executable_path = $allowed[0]; executable_sha256 = ("a" * 64)
        working_directory = (Split-Path -Parent $allowed[0])
        allowed_executable_path_count = $allowed.Count
        allowed_executable_paths_sha256 = $pathsDigest
        argument_count = 0; arguments_sha256 = ("b" * 64)
        timeout_seconds = 300; control_valid_until_utc = "2026-07-24T01:00:00Z"
        previous_receipt_sha256 = $null
    }
    $launchPath = Join-Path $Fixture.Paths.process_receipts "000-launch.json"
    Write-CgceJsonAtomic $launch $launchPath
    $childFileTime = [int64]$ProcessRecord.CreationTimeFileTimeUtc
    $rootPid = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_process_pid"
        run_id = $Fixture.Source.run_id; sequence = 1; pid = 42; parent_pid = 0
        executable_path = $allowed[0]
        creation_time_utc = [DateTime]::FromFileTimeUtc($childFileTime - 10000000).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        creation_time_filetime_utc = $childFileTime - 10000000
        observed_at_utc = [DateTime]::FromFileTimeUtc($childFileTime).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        previous_receipt_sha256 = (Get-CgceSha256 $launchPath)
    }
    $rootPath = Join-Path $Fixture.Paths.process_receipts "001-pid.json"
    Write-CgceJsonAtomic $rootPid $rootPath
    $child = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_process_pid"
        run_id = $Fixture.Source.run_id; sequence = 2
        pid = [int64]$ProcessRecord.ProcessId; parent_pid = 42
        executable_path = [string]$ProcessRecord.ExecutablePath
        creation_time_utc = [DateTime]::FromFileTimeUtc($childFileTime).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        creation_time_filetime_utc = $childFileTime
        observed_at_utc = [DateTime]::FromFileTimeUtc($childFileTime).AddSeconds(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        previous_receipt_sha256 = (Get-CgceSha256 $rootPath)
    }
    Write-CgceJsonAtomic $child (Join-Path $Fixture.Paths.process_receipts "002-pid.json")
}

Invoke-CgceTest "shared inventory tree digest freezes framing ordering and strict entries" {
    $entries = @(
        [pscustomobject][ordered]@{ relative_path = "a.txt"; length = [int64]3; sha256 = ("a" * 64) },
        [pscustomobject][ordered]@{ relative_path = "b/z.bin"; length = [int64]9; sha256 = ("b" * 64) }
    )
    Assert-CgceEqual `
        "412f6bcca9f94ba03373a6180ba1749034ab11912708a725605af2b32bc06c6b" `
        (Get-CgceInventoryTreeSha256 -Entries $entries)
    foreach ($invalid in @(
            @($entries[1], $entries[0]),
            @($entries[0], [pscustomobject]@{ relative_path = "a.txt"; length = 3; sha256 = ("a" * 64) }),
            @([pscustomobject]@{ relative_path = "a.txt"; length = 3; sha256 = ("a" * 64); foreign = $true })
        )) {
        Assert-CgceThrows "CGCE-OPS-INVENTORY" {
            Get-CgceInventoryTreeSha256 -Entries $invalid
        }
    }
}

Invoke-CgceTest "recovery intent accepts only the exact source preimage and fixed step schema" {
    foreach ($phase in @(
            "CREATED", "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED",
            "CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED"
        )) {
        foreach ($outcome in @("ACTIVE", "BLOCKED")) {
            $fixture = New-CgceRecoveryContractFixture $phase $outcome
            try {
                $source = Read-CgceJsonObject $fixture.Paths.state
                Assert-CgceEqual (Get-CgceSha256 $fixture.Paths.state) $fixture.Intent.source_state_sha256
                Assert-CgceEqual $source.phase $fixture.Intent.source_phase
                Assert-CgceEqual $source.outcome $fixture.Intent.source_outcome
                Assert-CgceEqual $source.revision $fixture.Intent.source_revision
                Assert-CgceEqual `
                    (ConvertTo-CgceContractTestJson $source.errors) `
                    (ConvertTo-CgceContractTestJson $fixture.Intent.source_errors)
                Assert-CgceEqual `
                    "schema_version,kind,run_id,sequence,created_at_utc,source_state_sha256,source_phase,source_outcome,source_revision,source_updated_at_utc,source_errors,genesis_state_sha256,original_inventory_sha256,original_tree_sha256,selected_case,paths,steps" `
                    ([string]::Join(",", @($fixture.Intent.PSObject.Properties.Name)))
                Assert-CgceEqual `
                    "active_saved,inactive_original,quarantined_clone,original_inventory,restored_inventory,restore_receipts,probe_restore_final_receipt" `
                    ([string]::Join(",", @($fixture.Intent.paths.PSObject.Properties.Name)))
                foreach ($step in @($fixture.Intent.steps)) {
                    Assert-CgceEqual `
                        "sequence,step,operation,source_path,destination_path,before_state,after_state" `
                        ([string]::Join(",", @($step.PSObject.Properties.Name)))
                    foreach ($pair in @($step.before_state, $step.after_state)) {
                        Assert-CgceEqual "source,destination" `
                            ([string]::Join(",", @($pair.PSObject.Properties.Name)))
                        foreach ($artifact in @($pair.source, $pair.destination)) {
                            Assert-CgceEqual `
                                "artifact_type,present,length,sha256,tree_sha256" `
                                ([string]::Join(",", @($artifact.PSObject.Properties.Name)))
                        }
                    }
                }
                $output = @(Write-CgceRecoveryRunState `
                    -StatePath $fixture.Paths.state `
                    -RecoveryIntentPath $fixture.IntentPath)
                Assert-CgceEqual 0 $output.Count
                $restoring = Read-CgceJsonObject $fixture.Paths.state
                Assert-CgceEqual "RESTORING" $restoring.phase
                Assert-CgceEqual ([int64]$source.revision + 1) ([int64]$restoring.revision)
                Assert-CgceEqual $source.outcome $restoring.outcome
                Assert-CgceRecoveryStateMatchesSource `
                    -Source $source `
                    -Actual $restoring `
                    -ExpectedPhase "RESTORING" `
                    -ExpectedRevision ([int64]$source.revision + 1) `
                    -ExpectedOutcome $source.outcome
                foreach ($field in @(
                        "inventory_checksums", "probe_receipt_checksum",
                        "process_launch_receipt_checksum", "process_result_receipt_checksum",
                        "capture_inventory_checksum", "errors"
                    )) {
                    Assert-CgceEqual `
                        (ConvertTo-CgceContractTestJson $source.$field) `
                        (ConvertTo-CgceContractTestJson $restoring.$field)
                }
            } catch {
                throw "CGCE-TEST $phase/${outcome}: $($_.Exception.Message)"
            } finally {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }

    foreach ($case in @(
            [pscustomobject]@{ Name = "source-state"; Mutate = {
                    param($Intent) $Intent.source_state_sha256 = ("f" * 64)
                } },
            [pscustomobject]@{ Name = "source-phase"; Mutate = {
                    param($Intent) $Intent.source_phase = "BACKUP_VERIFIED"
                } },
            [pscustomobject]@{ Name = "source-outcome"; Mutate = {
                    param($Intent) $Intent.source_outcome = "BLOCKED"
                } },
            [pscustomobject]@{ Name = "source-revision"; Mutate = {
                    param($Intent) $Intent.source_revision = [int64]$Intent.source_revision + 1
                } },
            [pscustomobject]@{ Name = "source-updated"; Mutate = {
                    param($Intent)
                    $Intent.source_updated_at_utc = [DateTime]::UtcNow.AddHours(1).ToString(
                        "yyyy-MM-dd'T'HH:mm:ss'Z'",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } },
            [pscustomobject]@{ Name = "source-errors"; Mutate = {
                    param($Intent)
                    $Intent.source_errors = @([pscustomobject]@{
                        code = "CGCE-OPS-FOREIGN"
                        at_utc = [DateTime]::UtcNow.AddHours(1).ToString(
                            "yyyy-MM-dd'T'HH:mm:ss'Z'",
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                    })
                } },
            [pscustomobject]@{ Name = "genesis"; Mutate = {
                    param($Intent) $Intent.genesis_state_sha256 = ("f" * 64)
                } },
            [pscustomobject]@{ Name = "original-inventory"; Mutate = {
                    param($Intent) $Intent.original_inventory_sha256 = ("f" * 64)
                } },
            [pscustomobject]@{ Name = "original-tree"; Mutate = {
                    param($Intent) $Intent.original_tree_sha256 = ("f" * 64)
                } },
            [pscustomobject]@{ Name = "selected-case"; Mutate = {
                    param($Intent) $Intent.selected_case = "NO_ACTIVE_AND_INACTIVE_ORIGINAL"
                } },
            [pscustomobject]@{ Name = "path"; Mutate = {
                    param($Intent) $Intent.paths.active_saved += ".foreign"
                } },
            [pscustomobject]@{ Name = "foreign-path-key"; Mutate = {
                    param($Intent) $Intent.paths | Add-Member -NotePropertyName foreign -NotePropertyValue "x"
                } },
            [pscustomobject]@{ Name = "foreign-intent-key"; Mutate = {
                    param($Intent) $Intent | Add-Member -NotePropertyName foreign -NotePropertyValue "x"
                } },
            [pscustomobject]@{ Name = "missing-intent-key"; Mutate = {
                    param($Intent) $Intent.PSObject.Properties.Remove("created_at_utc")
                } },
            [pscustomobject]@{ Name = "step-order"; Mutate = {
                    param($Intent) $Intent.steps = @($Intent.steps[1], $Intent.steps[0])
                } },
            [pscustomobject]@{ Name = "step-sequence"; Mutate = {
                    param($Intent) $Intent.steps[0].sequence = 11
                } },
            [pscustomobject]@{ Name = "step-name"; Mutate = {
                    param($Intent) $Intent.steps[0].step = "RESTORE_ORIGINAL"
                } },
            [pscustomobject]@{ Name = "step-operation"; Mutate = {
                    param($Intent) $Intent.steps[0].operation = "VERIFY_ABSENT"
                } },
            [pscustomobject]@{ Name = "step-source-path"; Mutate = {
                    param($Intent) $Intent.steps[0].source_path += ".foreign"
                } },
            [pscustomobject]@{ Name = "step-destination-path"; Mutate = {
                    param($Intent) $Intent.steps[0].destination_path += ".foreign"
                } },
            [pscustomobject]@{ Name = "foreign-step-key"; Mutate = {
                    param($Intent) $Intent.steps[0] |
                        Add-Member -NotePropertyName foreign -NotePropertyValue "x"
                } },
            [pscustomobject]@{ Name = "missing-step-key"; Mutate = {
                    param($Intent) $Intent.steps[0].PSObject.Properties.Remove("operation")
                } },
            [pscustomobject]@{ Name = "foreign-pair-key"; Mutate = {
                    param($Intent) $Intent.steps[0].before_state |
                        Add-Member -NotePropertyName foreign -NotePropertyValue "x"
                } },
            [pscustomobject]@{ Name = "missing-pair-key"; Mutate = {
                    param($Intent)
                    $Intent.steps[0].before_state.PSObject.Properties.Remove("destination")
                } },
            [pscustomobject]@{ Name = "foreign-artifact-key"; Mutate = {
                    param($Intent) $Intent.steps[0].before_state.source |
                        Add-Member -NotePropertyName foreign -NotePropertyValue "x"
                } },
            [pscustomobject]@{ Name = "missing-artifact-key"; Mutate = {
                    param($Intent)
                    $Intent.steps[0].before_state.source.PSObject.Properties.Remove("tree_sha256")
                } },
            [pscustomobject]@{ Name = "extra-step"; Mutate = {
                    param($Intent) $Intent.steps = @($Intent.steps) + @($Intent.steps[1])
                } }
        )) {
        $fixture = New-CgceRecoveryContractFixture
        try {
            $intent = Read-CgceJsonObject $fixture.IntentPath
            $mutator = $case.Mutate
            $null = & $mutator $intent
            Write-CgceContractTestUtf8 `
                $fixture.IntentPath `
                (ConvertTo-CgceContractTestJson $intent)
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-" {
                Write-CgceRecoveryRunState `
                    $fixture.Paths.state `
                    $fixture.IntentPath
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        } catch {
            throw "CGCE-TEST intent rejection $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CgceTest "recovery process identity normalizes sub-microsecond drift but preserves one-microsecond drift" {
    $contract = Get-Module "CgceDiscovery.Contract"
    $baseFileTime = [int64]134292420610000000
    $values = @(
        foreach ($offset in @(0, 4, 10)) {
            & $contract {
                param([int64]$FileTime)
                ConvertTo-CgceRecoveryCanonicalProcessFileTime $FileTime
            } ($baseFileTime + $offset)
        }
    )
    Assert-CgceEqual $values[0] $values[1]
    Assert-CgceEqual ($baseFileTime + 10) $values[2]
    Assert-CgceEqual $false ([int64]$values[0] -eq [int64]$values[2])
}

Invoke-CgceTest "recovery state inactivity matches Runtime over process PID and port fixtures" {
    $reservation = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $reservation.Start()
    $freePort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $fixture = New-CgceRecoveryContractFixture -ListenerPort $freePort
    $process = $null
    try {
        $unlisted = Join-Path $fixture.Root "unlisted\child.exe"
        New-Item -ItemType Directory -Path (Split-Path -Parent $unlisted) -Force | Out-Null
        Copy-Item -LiteralPath $env:ComSpec -Destination $unlisted
        $process = Start-Process `
            -FilePath $unlisted `
            -ArgumentList @("/c", "ping -n 10 127.0.0.1 >nul") `
            -PassThru
        $record = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($null -eq $record -and [DateTime]::UtcNow -lt $deadline) {
            $record = Get-CimInstance Win32_Process `
                -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue
            if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.ExecutablePath)) {
                $record = $null
                Start-Sleep -Milliseconds 50
            }
        }
        if ($null -eq $record) { throw "CGCE-TEST process telemetry readiness timeout" }
        $created = if ($record.CreationDate -is [DateTime]) {
            ([DateTime]$record.CreationDate).ToUniversalTime()
        } else {
            [Management.ManagementDateTimeConverter]::ToDateTime([string]$record.CreationDate).ToUniversalTime()
        }
        $activityRecord = [pscustomobject]@{
            ProcessId = [int64]$record.ProcessId
            ParentProcessId = [int64]$record.ParentProcessId
            ExecutablePath = [string]$record.ExecutablePath
            CreationTimeFileTimeUtc = $created.ToFileTimeUtc()
        }
        Add-CgceContractUnlistedPidReceipts $fixture $activityRecord
        Set-CgceContractRuntimeSnapshot `
            (New-CgceContractRuntimeSnapshot @($activityRecord) @())
        $before = Get-CgceSha256 $fixture.Paths.state
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Assert-CgceNoServerActivity `
                $fixture.Source.server_process_paths `
                $fixture.Source.listener_ports `
                $fixture.Paths.process_receipts
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        }
        Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($null -ne (Get-CimInstance Win32_Process `
                -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue) -and
            [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        if ($null -ne (Get-CimInstance Win32_Process `
                -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue)) {
            throw "CGCE-TEST process exit telemetry timeout"
        }
        Set-CgceContractRuntimeSnapshot (New-CgceContractRuntimeSnapshot @() @())
        Assert-CgceNoServerActivity `
            $fixture.Source.server_process_paths `
            $fixture.Source.listener_ports `
            $fixture.Paths.process_receipts
        $output = @(Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath)
        Assert-CgceEqual 0 $output.Count
    } finally {
        Set-CgceContractRuntimeSnapshot $null
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
        }
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }

    $reservation = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $reservation.Start()
    $freePort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $fixture = New-CgceRecoveryContractFixture -ListenerPort $freePort
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $freePort
    try {
        $listener.Start()
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $ready = $false
        while (-not $ready -and [DateTime]::UtcNow -lt $deadline) {
            $ready = @(
                Get-NetTCPConnection -LocalPort $freePort -State Listen -ErrorAction SilentlyContinue
            ).Count -gt 0
            if (-not $ready) { Start-Sleep -Milliseconds 50 }
        }
        if (-not $ready) { throw "CGCE-TEST listener telemetry readiness timeout" }
        Set-CgceContractRuntimeSnapshot (New-CgceContractRuntimeSnapshot @() @(
            [pscustomobject]@{ LocalPort = $freePort; State = "Listen" }
        ))
        $before = Get-CgceSha256 $fixture.Paths.state
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Assert-CgceNoServerActivity `
                $fixture.Source.server_process_paths `
                $fixture.Source.listener_ports `
                $fixture.Paths.process_receipts
        }
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        }
        Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        $listener.Stop()
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (@(
                Get-NetTCPConnection -LocalPort $freePort -State Listen `
                    -ErrorAction SilentlyContinue
            ).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        if (@(
                Get-NetTCPConnection -LocalPort $freePort -State Listen `
                    -ErrorAction SilentlyContinue
            ).Count -gt 0) {
            throw "CGCE-TEST listener exit telemetry timeout"
        }
        Set-CgceContractRuntimeSnapshot (New-CgceContractRuntimeSnapshot @() @())
        Assert-CgceNoServerActivity `
            $fixture.Source.server_process_paths `
            $fixture.Source.listener_ports `
            $fixture.Paths.process_receipts
        $output = @(Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath)
        Assert-CgceEqual 0 $output.Count
    } finally {
        Set-CgceContractRuntimeSnapshot $null
        try {
            $listener.Stop()
        } catch { }
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

Invoke-CgceTest "recovery probe completion matches Runtime over journal and terminal fixtures" {
    $fixture = New-CgceRecoveryContractFixture
    try {
        $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        Write-CgceContractRecoveryJournal $fixture
        $runtimeOutput = @(Assert-CgceInventoryProbeRestored `
            -Paths $fixture.Paths `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.Source.run_id)
        Assert-CgceEqual 0 $runtimeOutput.Count
        $output = @(Complete-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath)
        Assert-CgceEqual 0 $output.Count
        Assert-CgceEqual "RESTORED" (Read-CgceJsonObject $fixture.Paths.state).phase
    } finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }

    $fixture = New-CgceRecoveryContractFixture
    try {
        $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        Write-CgceContractRecoveryJournal $fixture
        New-Item -ItemType Directory -Path $fixture.Paths.probe_staged -Force | Out-Null
        Write-CgceContractTestUtf8 (Join-Path $fixture.Paths.probe_staged "foreign.lua") "foreign"
        $runtimeCode = Get-CgceContractErrorCode {
            Assert-CgceInventoryProbeRestored `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.Source.run_id
        }
        $before = Get-CgceSha256 $fixture.Paths.state
        $contractCode = Get-CgceContractErrorCode {
            Complete-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        }
        Assert-CgceEqual $false ([string]::IsNullOrEmpty($runtimeCode))
        Assert-CgceEqual $runtimeCode $contractCode
        Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
    } finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }

    $fixture = New-CgceRecoveryContractFixture -SourcePhase "PROBE_STAGED"
    try {
        $probe = Initialize-CgceContractProbeRecoveryAuthority $fixture
        Complete-CgceContractRecoveryFilesystem $fixture
        Write-CgceContractRecoveryJournal $fixture
        $runtimeOutput = @(Assert-CgceInventoryProbeRestored `
            -Paths $fixture.Paths `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.Source.run_id `
            -ExpectedFinalReceiptChecksum $probe.StageChecksum)
        Assert-CgceEqual 0 $runtimeOutput.Count
        $output = @(Complete-CgceRecoveryRunState `
            $fixture.Paths.state `
            $fixture.IntentPath)
        Assert-CgceEqual 0 $output.Count
        $restored = Read-CgceJsonObject $fixture.Paths.state
        Assert-CgceRecoveryStateMatchesSource `
            -Source $fixture.Source `
            -Actual $restored `
            -ExpectedPhase "RESTORED" `
            -ExpectedRevision ([int64]$fixture.Source.revision + 2) `
            -ExpectedOutcome $fixture.Source.outcome `
            -RestoredChecksum (Get-CgceSha256 $fixture.Paths.restored_inventory)
    } finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }

    foreach ($tamper in @("journal", "terminal")) {
        $fixture = New-CgceRecoveryContractFixture -SourcePhase "PROBE_STAGED"
        try {
            $probe = Initialize-CgceContractProbeRecoveryAuthority $fixture
            Complete-CgceContractRecoveryFilesystem $fixture
            Write-CgceContractRecoveryJournal $fixture
            if ($tamper -ceq "journal") {
                $path = Join-Path $fixture.Paths.probe_receipts `
                    "restore\010-quarantine-probe.json"
                $receipt = Read-CgceJsonObject $path
                $receipt.operation = "VERIFY_ABSENT"
                Write-CgceContractTestUtf8 `
                    $path `
                    (ConvertTo-CgceContractTestJson $receipt)
            } else {
                Move-CgceDirectoryNoOverwrite `
                    $fixture.Paths.probe_quarantine `
                    $fixture.Paths.probe_staged
            }
            $before = Get-CgceSha256 $fixture.Paths.state
            $runtimeCode = Get-CgceContractErrorCode {
                Assert-CgceInventoryProbeRestored `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.Source.run_id `
                    -ExpectedFinalReceiptChecksum $probe.StageChecksum
            }
            $contractCode = Get-CgceContractErrorCode {
                Complete-CgceRecoveryRunState `
                    $fixture.Paths.state `
                    $fixture.IntentPath
            }
            Assert-CgceEqual $false ([string]::IsNullOrEmpty($runtimeCode))
            Assert-CgceEqual $runtimeCode $contractCode
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        } catch {
            throw "CGCE-TEST probe parity ${tamper}: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CgceTest "recovery state writers reject state-only and sentinel-only manual barriers" {
    foreach ($barrier in @("state", "sentinel")) {
        $fixture = if ($barrier -ceq "state") {
            New-CgceRecoveryContractFixture -Outcome "BLOCKED" -ManualStateError $true
        } else {
            New-CgceRecoveryContractFixture
        }
        try {
            if ($barrier -ceq "sentinel") { Add-CgceContractManualSentinel $fixture }
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)

            Set-CgceContractFixtureRestoring $fixture
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                Block-CgceRecoveryRunState `
                    $fixture.Paths.state $fixture.IntentPath "CGCE-OPS-RECOVERY-FAILED"
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)

            Write-CgceContractRecoveryJournal $fixture
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                Complete-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CgceTest "recovery blocker owns exact ACTIVE and BLOCKED revision-plus-two deltas" {
    foreach ($outcome in @("ACTIVE", "BLOCKED")) {
        $fixture = New-CgceRecoveryContractFixture -Outcome $outcome
        try {
            $source = Read-CgceJsonObject $fixture.Paths.state
            $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            $output = @(Block-CgceRecoveryRunState `
                -StatePath $fixture.Paths.state `
                -RecoveryIntentPath $fixture.IntentPath `
                -Code "CGCE-OPS-RECOVERY-FAILED")
            Assert-CgceEqual 0 $output.Count
            $blocked = Read-CgceJsonObject $fixture.Paths.state
            Assert-CgceEqual "RESTORING" $blocked.phase
            Assert-CgceEqual "BLOCKED" $blocked.outcome
            Assert-CgceEqual ([int64]$source.revision + 2) ([int64]$blocked.revision)
            Assert-CgceRecoveryStateMatchesSource `
                -Source $source `
                -Actual $blocked `
                -ExpectedPhase "RESTORING" `
                -ExpectedRevision ([int64]$source.revision + 2) `
                -ExpectedOutcome "BLOCKED" `
                -AppendError $true `
                -AppendedCode "CGCE-OPS-RECOVERY-FAILED"
            Assert-CgceEqual ($source.errors.Count + 1) $blocked.errors.Count
            for ($index = 0; $index -lt $source.errors.Count; $index += 1) {
                Assert-CgceEqual `
                    (ConvertTo-CgceContractTestJson $source.errors[$index]) `
                    (ConvertTo-CgceContractTestJson $blocked.errors[$index])
            }
            Assert-CgceEqual "CGCE-OPS-RECOVERY-FAILED" $blocked.errors[-1].code
            Assert-CgceEqual $true `
                ([string]$blocked.errors[-1].at_utc -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')
            foreach ($field in @(
                    "inventory_checksums", "probe_receipt_checksum",
                    "process_launch_receipt_checksum", "process_result_receipt_checksum",
                    "capture_inventory_checksum"
                )) {
                Assert-CgceEqual `
                    (ConvertTo-CgceContractTestJson $source.$field) `
                    (ConvertTo-CgceContractTestJson $blocked.$field)
            }
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }

    foreach ($case in @(
            "invalid", "lf", "crlf", "pre-cas", "already-n-plus-two",
            "stale", "changed-evidence", "changed-errors", "missing-intent",
            "mismatched-intent"
        )) {
        $fixture = New-CgceRecoveryContractFixture
        try {
            if ($case -cnotin @("pre-cas", "stale", "changed-evidence", "changed-errors")) {
                $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            }
            switch ($case) {
                "already-n-plus-two" {
                    $null = Block-CgceRecoveryRunState `
                        $fixture.Paths.state $fixture.IntentPath "CGCE-OPS-RECOVERY-FAILED"
                }
                "stale" {
                    Set-CgceContractFixtureRestoring $fixture
                    $state = Read-CgceJsonObject $fixture.Paths.state
                    $state.revision = [int64]$fixture.Intent.source_revision
                    Write-CgceContractTestUtf8 $fixture.Paths.state (ConvertTo-CgceContractTestJson $state)
                }
                "changed-evidence" {
                    Set-CgceContractFixtureRestoring $fixture
                    $state = Read-CgceJsonObject $fixture.Paths.state
                    $state.inventory_checksums.backup = ("f" * 64)
                    Write-CgceContractTestUtf8 $fixture.Paths.state (ConvertTo-CgceContractTestJson $state)
                }
                "changed-errors" {
                    Set-CgceContractFixtureRestoring $fixture
                    $state = Read-CgceJsonObject $fixture.Paths.state
                    $state.outcome = "BLOCKED"
                    $state.errors = @([pscustomobject]@{
                        code = "CGCE-OPS-FOREIGN"
                        at_utc = $fixture.CreatedAt.AddSeconds(3).ToString(
                            "yyyy-MM-dd'T'HH:mm:ss'Z'",
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                    })
                    Write-CgceContractTestUtf8 $fixture.Paths.state (ConvertTo-CgceContractTestJson $state)
                }
                "missing-intent" { Remove-Item -LiteralPath $fixture.IntentPath }
                "mismatched-intent" {
                    $intent = Read-CgceJsonObject $fixture.IntentPath
                    $intent.source_revision = [int64]$intent.source_revision + 1
                    Write-CgceContractTestUtf8 $fixture.IntentPath (ConvertTo-CgceContractTestJson $intent)
                }
            }
            $code = switch ($case) {
                "invalid" { "FOREIGN" }
                "lf" { "CGCE-OPS-RECOVERY-FAILED`n" }
                "crlf" { "CGCE-OPS-RECOVERY-FAILED`r`n" }
                default { "CGCE-OPS-RECOVERY-FAILED" }
            }
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-" {
                Block-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath $code
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        } catch {
            throw "CGCE-TEST blocker rejection ${case}: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CgceTest "recovery completion requires exact 000 010 020 999 authority" {
    $fixture = New-CgceRecoveryContractFixture
    try {
        $source = Read-CgceJsonObject $fixture.Paths.state
        $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
        Write-CgceContractRecoveryJournal $fixture
        $authorityPaths = @(
            $fixture.IntentPath,
            (Join-Path $fixture.Paths.restore_receipts "010-quarantine-clone.json"),
            (Join-Path $fixture.Paths.restore_receipts "020-restore-original.json"),
            (Join-Path $fixture.Paths.restore_receipts "999-restore-final.json"),
            $fixture.Paths.original_inventory,
            $fixture.Paths.restored_inventory
        )
        $authorityBefore = @($authorityPaths | ForEach-Object { Get-CgceSha256 $_ })
        $output = @(Complete-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath)
        Assert-CgceEqual 0 $output.Count
        $restored = Read-CgceJsonObject $fixture.Paths.state
        Assert-CgceEqual "RESTORED" $restored.phase
        Assert-CgceEqual ([int64]$source.revision + 2) ([int64]$restored.revision)
        Assert-CgceEqual $source.outcome $restored.outcome
        $restoredChecksum = Get-CgceSha256 $fixture.Paths.restored_inventory
        Assert-CgceRecoveryStateMatchesSource `
            -Source $source `
            -Actual $restored `
            -ExpectedPhase "RESTORED" `
            -ExpectedRevision ([int64]$source.revision + 2) `
            -ExpectedOutcome $source.outcome `
            -RestoredChecksum $restoredChecksum
        Assert-CgceEqual `
            (ConvertTo-CgceContractTestJson $source.errors) `
            (ConvertTo-CgceContractTestJson $restored.errors)
        foreach ($field in @(
                "original", "backup", "clone"
            )) {
            Assert-CgceDeepEqual `
                $source.inventory_checksums.$field `
                $restored.inventory_checksums.$field
        }
        foreach ($field in @(
                "probe_receipt_checksum", "process_launch_receipt_checksum",
                "process_result_receipt_checksum", "capture_inventory_checksum"
            )) {
            Assert-CgceDeepEqual $source.$field $restored.$field
        }
        Assert-CgceEqual $restoredChecksum `
            $restored.inventory_checksums.restored
        Assert-CgceDeepEqual `
            $authorityBefore `
            @($authorityPaths | ForEach-Object { Get-CgceSha256 $_ })
    } finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }

    foreach ($case in @("missing", "gap", "foreign", "tamper")) {
        $fixture = New-CgceRecoveryContractFixture
        try {
            $null = Write-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            Write-CgceContractRecoveryJournal $fixture
            if ($case -ceq "missing") {
                Remove-Item -LiteralPath (
                    Join-Path $fixture.Paths.restore_receipts "999-restore-final.json"
                )
            } elseif ($case -ceq "gap") {
                Remove-Item -LiteralPath (
                    Join-Path $fixture.Paths.restore_receipts "010-quarantine-clone.json"
                )
            } elseif ($case -ceq "foreign") {
                Write-CgceContractTestUtf8 `
                    (Join-Path $fixture.Paths.restore_receipts "021-foreign.json") "{}"
            } elseif ($case -ceq "tamper") {
                $path = Join-Path $fixture.Paths.restore_receipts "010-quarantine-clone.json"
                $receipt = Read-CgceJsonObject $path
                $receipt.operation = "VERIFY_ABSENT"
                Write-CgceContractTestUtf8 $path (ConvertTo-CgceContractTestJson $receipt)
            }
            $snapshotBefore = Get-CgceContractFixtureSnapshot $fixture
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceThrows "CGCE-OPS-RESTORE-RECEIPT" {
                Complete-CgceRecoveryRunState $fixture.Paths.state $fixture.IntentPath
            }
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
            Assert-CgceDeepEqual `
                $snapshotBefore `
                (Get-CgceContractFixtureSnapshot $fixture)
        } catch {
            throw "CGCE-TEST completion rejection ${case}: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}
