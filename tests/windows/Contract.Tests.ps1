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
        Write-CgceJsonAtomic $state $paths.genesis_state
        Write-CgceJsonAtomic $state $paths.state

        $state = Set-CgceRunPhase $state "CREATED" "BACKUP_VERIFIED"
        Write-CgceRunState -State $state -StatePath $paths.state -ExpectedPhase "CREATED"
        $read = Read-CgceRunState -RunRoot $root -RunId $state.run_id
        Assert-CgceEqual "BACKUP_VERIFIED" $read.phase
        Assert-CgceEqual 1 $read.revision
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run-state post-replace read-back rejects checksum drift" {
    $root = New-CgceContractTestRoot
    try {
        $paths = New-CgceContractTestPaths $root
        New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
        New-Item -ItemType Directory -Path $paths.server_root | Out-Null
        $state = New-CgceRunState `
            -RunId "r-0123456789abcdef0123456789abcdef" `
            -MaintenanceId "m-0123456789abcdef0123456789abcdef" `
            -Paths $paths
        Write-CgceJsonAtomic $state $paths.state
        $module = Get-Module "CgceDiscovery.Contract"
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            & $module {
                param($StatePath)
                Confirm-CgceRunStateReadBack `
                    -StatePath $StatePath `
                    -ExpectedChecksum ("f" * 64) `
                    -ExpectedRevision 0 `
                    -ExpectedPhase "CREATED"
            } $paths.state
        }
    } finally {
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
