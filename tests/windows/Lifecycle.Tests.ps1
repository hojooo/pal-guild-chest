Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\CgceDiscovery.Common.psm1" -Force

function Write-CgceLifecycleUtf8([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-CgceLifecycleHandoffPaths {
    return @(
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
}

function New-CgceSyntheticFixture {
    $base = Join-Path $env:TEMP ("cgce-lifecycle-" + [guid]::NewGuid().ToString("N"))
    $serverRoot = Join-Path $base "server"
    $savedPath = Join-Path $serverRoot "Pal\Saved"
    $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
    $modsRoot = Join-Path $ue4ssRoot "Mods"
    $runRoot = Join-Path $base "runs"
    $handoffRoot = Join-Path $base "handoff"
    $runId = "r-" + [guid]::NewGuid().ToString("N")
    New-Item -ItemType Directory -Path $savedPath -Force | Out-Null
    New-Item -ItemType Directory -Path $modsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    New-Item -ItemType Directory -Path $handoffRoot | Out-Null
    Write-CgceLifecycleUtf8 (Join-Path $savedPath "WorldOption.sav") "synthetic-world"
    New-Item -ItemType Directory -Path (Join-Path $savedPath "Players") | Out-Null
    Write-CgceLifecycleUtf8 (Join-Path $savedPath "Players\synthetic.sav") "synthetic-player"
    Write-CgceLifecycleUtf8 (Join-Path $ue4ssRoot "UE4SS.dll") "synthetic-ue4ss"
    Write-CgceLifecycleUtf8 (Join-Path $modsRoot "mods.txt") "BPModLoaderMod : 1`r`n"

    $serverExecutable = Join-Path $serverRoot "PalServer.exe"
    $cmd = Join-Path $env:SystemRoot "System32\cmd.exe"
    [System.IO.File]::Copy($cmd, $serverExecutable, $false)

    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $handoffRecords = New-Object 'System.Collections.Generic.List[string]'
    $handoffPaths = @(Get-CgceLifecycleHandoffPaths)
    [Array]::Sort($handoffPaths, [StringComparer]::Ordinal)
    foreach ($relative in $handoffPaths) {
        $destination = Join-Path $handoffRoot ($relative -replace '/', '\')
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $source = Join-Path $repositoryRoot ($relative -replace '/', '\')
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            [System.IO.File]::Copy($source, $destination, $false)
        } else {
            Write-CgceLifecycleUtf8 $destination ("synthetic " + $relative)
        }
        $handoffRecords.Add((Get-CgceSha256 $destination) + "  " + $relative)
    }
    $sourceManifestPath = Join-Path $handoffRoot "source-manifest.sha256"
    Write-CgceLifecycleUtf8 `
        $sourceManifestPath `
        (($handoffRecords.ToArray() -join "`n") + "`n")

    $bundleSha = "a" * 64
    $verifiedAt = [DateTime]::UtcNow.AddMinutes(-1)
    $validUntil = $verifiedAt.AddHours(3)
    $control = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_control"
        maintenance_id = "m-" + [guid]::NewGuid().ToString("N")
        run_id = $runId
        operator = "synthetic-operator"
        server_root = $serverRoot
        palserver_executable = $serverExecutable
        server_process_paths = @($serverExecutable)
        server_process_paths_complete = $true
        ue4ss_root = $ue4ssRoot
        ue4ss_version = "3.0.1"
        ue4ss_dll_sha256 = (Get-CgceSha256 (Join-Path $ue4ssRoot "UE4SS.dll"))
        listener_ports = @(65534)
        production_restart_disabled = $true
        external_access_blocked = $true
        players_disconnected = $true
        bundle_checksum = $bundleSha
        verified_at_utc = $verifiedAt.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        valid_until_utc = $validUntil.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    $controlPath = Join-Path $base "control-evidence.json"
    Write-CgceLifecycleUtf8 $controlPath ($control | ConvertTo-Json -Depth 8)
    $paths = New-CgceRunPaths `
        -ServerRoot $serverRoot -SavedPath $savedPath `
        -Ue4ssRoot $ue4ssRoot -RunRoot $runRoot -RunId $runId
    return [pscustomobject]@{
        Base = $base
        ServerRoot = $serverRoot
        SavedPath = $savedPath
        Ue4ssRoot = $ue4ssRoot
        ServerExecutable = $serverExecutable
        RunRoot = $runRoot
        RunId = $runId
        HandoffRoot = $handoffRoot
        SourceManifestPath = $sourceManifestPath
        SourceManifestSha = (Get-CgceSha256 $sourceManifestPath)
        ControlPath = $controlPath
        ControlSha = (Get-CgceSha256 $controlPath)
        BundleSha = $bundleSha
        Paths = $paths
        OriginalInventory = @(Get-CgceTreeInventory -Root $savedPath)
        PrepareScript = (Join-Path `
            $handoffRoot `
            "tools\windows-discovery\Prepare-CgceDiscovery.ps1")
        RepositoryPrepareScript = (Join-Path `
            $repositoryRoot `
            "tools\windows-discovery\Prepare-CgceDiscovery.ps1")
    }
}

function ConvertTo-CgceLifecycleSingleQuoted([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-CgcePrepareChild(
    $Fixture,
    [string]$ModuleSetup = ""
) {
    $stderrPath = Join-Path $Fixture.Base ("prepare-stderr-" + [guid]::NewGuid().ToString("N"))
    $entryScript = $Fixture.PrepareScript
    if (-not [string]::IsNullOrWhiteSpace($ModuleSetup)) {
        $entryScript = Join-Path $Fixture.Base (
            "prepare-wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1"
        )
        $toolRoot = Join-Path $Fixture.HandoffRoot "tools\windows-discovery"
        $wrapper = @(
            '$ErrorActionPreference = "Stop"'
            ('$commonModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "CgceDiscovery.Common.psm1"
                )) + ' -Global -PassThru')
            ('$contractModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Contract.psm1"
                )) + ' -Global -PassThru')
            ('$filesModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Files.psm1"
                )) + ' -Global -PassThru')
            ('$runtimeModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Runtime.psm1"
                )) + ' -Global -PassThru')
            $ModuleSetup
            ('& ' + (ConvertTo-CgceLifecycleSingleQuoted $Fixture.PrepareScript) +
                ' @args')
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        Write-CgceLifecycleUtf8 -Path $entryScript -Text ($wrapper + "`r`n")
    }
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryScript,
        "-ServerRoot", $Fixture.ServerRoot,
        "-SavedPath", $Fixture.SavedPath,
        "-Ue4ssRoot", $Fixture.Ue4ssRoot,
        "-ServerExecutable", $Fixture.ServerExecutable,
        "-RunRoot", $Fixture.RunRoot,
        "-RunId", $Fixture.RunId,
        "-HandoffRoot", $Fixture.HandoffRoot,
        "-SourceManifestPath", $Fixture.SourceManifestPath,
        "-ControlEvidencePath", $Fixture.ControlPath,
        "-ControlEvidenceSha256", $Fixture.ControlSha,
        "-BundleSha256", $Fixture.BundleSha
    )
    $stdout = @(& "$PSHOME\powershell.exe" @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($stderrPath)
    } else {
        ""
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Update-CgceLifecycleControl(
    $Fixture,
    [scriptblock]$Mutation
) {
    $control = Read-CgceJsonObject -Path $Fixture.ControlPath
    $null = & $Mutation $control $Fixture
    Write-CgceLifecycleUtf8 `
        -Path $Fixture.ControlPath `
        -Text ($control | ConvertTo-Json -Depth 8)
    $Fixture.ControlSha = Get-CgceSha256 $Fixture.ControlPath
}

function Assert-CgcePreparePreGenesisBlocked(
    $Fixture,
    [string]$ExpectedCode
) {
    $result = Invoke-CgcePrepareChild $Fixture
    Assert-CgceEqual $true ($result.ExitCode -ne 0)
    Assert-CgceEqual 1 @($result.Stdout).Count
    Assert-CgceEqual `
        "CGCE_WINDOWS_DISCOVERY_BLOCKED $ExpectedCode $($Fixture.RunId)" `
        $result.Stdout[0]
    Assert-CgceEqual "" $result.Stderr
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.state)
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.genesis_state)
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.inactive_original)
    Compare-CgceInventory `
        -Expected $Fixture.OriginalInventory `
        -Actual @(Get-CgceTreeInventory -Root $Fixture.Paths.active_saved)
}

function New-CgcePersistenceFaultSetup(
    $Fixture,
    [bool]$FailAfterBackupState,
    [bool]$FailBlockedPersistence
) {
    $template = @'
& $contractModule {
    param(
        [string]$serverRoot,
        [string]$lockEvidence,
        [bool]$failAfterBackupState,
        [bool]$failBlockedPersistence
    )
    $stateFaultFired = $false
    $script:CgceTestStatePersistenceSeam = {
        param([string]$phase, $context)
        if ($failAfterBackupState -and -not $stateFaultFired -and
            $phase -ceq "after-state-replace" -and
            $context.candidate.phase -ceq "BACKUP_VERIFIED" -and
            $context.candidate.outcome -ceq "ACTIVE") {
            $stateFaultFired = $true
            throw "CGCE-OPS-CHECKSUM injected state read-back fault"
        }
        if ($phase -ceq "before-state-replace" -and
            $context.candidate.outcome -ceq "BLOCKED") {
            $contended = $false
            try {
                $otherLock = Enter-CgceExclusiveLock `
                    -ServerRoot $serverRoot `
                    -RunId $context.candidate.run_id
                $otherLock.Dispose()
            } catch {
                $contended = $true
            }
            if (-not $contended) {
                throw "CGCE-TEST Prepare lock was not held during blocking"
            }
            [System.IO.File]::WriteAllText(
                $lockEvidence,
                "held",
                (New-Object System.Text.UTF8Encoding($false))
            )
            if ($failBlockedPersistence) {
                throw "CGCE-OPS-CHECKSUM injected blocked persistence fault"
            }
        }
    }.GetNewClosure()
} __SERVER_ROOT__ __LOCK_EVIDENCE__ __FAIL_STATE__ __FAIL_BLOCK__
'@
    $result = $template.Replace(
        "__SERVER_ROOT__",
        (ConvertTo-CgceLifecycleSingleQuoted $Fixture.ServerRoot)
    )
    $result = $result.Replace(
        "__LOCK_EVIDENCE__",
        (ConvertTo-CgceLifecycleSingleQuoted (
            Join-Path $Fixture.Base "lock-held.txt"
        ))
    )
    $result = $result.Replace(
        "__FAIL_STATE__",
        $(if ($FailAfterBackupState) { '$true' } else { '$false' })
    )
    $result = $result.Replace(
        "__FAIL_BLOCK__",
        $(if ($FailBlockedPersistence) { '$true' } else { '$false' })
    )
    return $result
}

function New-CgceFileFaultSetup(
    [string]$Kind,
    [string]$Target,
    [string]$MutationPath = ""
) {
    $template = @'
& $filesModule {
    param([string]$kind, [string]$target, [string]$mutationPath)
    $script:CgceTestPublishSeam = {
        param([string]$phase, $context)
        if ($kind -ceq "tree-before" -and
            $phase -ceq "tree-before-publish" -and
            $context.destination -ceq $target) {
            throw "CGCE-OPS-COPY injected tree publication fault"
        }
        if ($kind -ceq "move-before" -and
            $phase -ceq "move-before-publish" -and
            $context.destination -ceq $target) {
            throw "CGCE-OPS-COPY injected rename fault"
        }
        if ($kind -ceq "tree-after-mutate" -and
            $phase -ceq "tree-after-publish" -and
            $context.destination -ceq $target) {
            [System.IO.File]::AppendAllText(
                $mutationPath,
                "drift",
                (New-Object System.Text.UTF8Encoding($false))
            )
        }
    }.GetNewClosure()
} __KIND__ __TARGET__ __MUTATION__
'@
    $result = $template.Replace(
        "__KIND__",
        (ConvertTo-CgceLifecycleSingleQuoted $Kind)
    )
    $result = $result.Replace(
        "__TARGET__",
        (ConvertTo-CgceLifecycleSingleQuoted $Target)
    )
    $result = $result.Replace(
        "__MUTATION__",
        (ConvertTo-CgceLifecycleSingleQuoted $MutationPath)
    )
    return $result
}

function New-CgceProbeFaultSetup {
    return @'
& $runtimeModule {
    $script:CgceTestProbeCrashSeam = {
        param([string]$point)
        if ($point -ceq "before-receipt-999") {
            throw "CGCE-OPS-PROBE-RECEIPT injected final receipt fault"
        }
    }
}
'@
}

function New-CgceActivityDriftSetup(
    $Fixture,
    [ValidateSet("process", "listener")]
    [string]$Kind
) {
    $template = @'
& $runtimeModule {
    param([string]$kind, [string]$serverExecutable)
    $calls = 0
    $script:CgceTestActivitySnapshotSeam = {
        $calls += 1
        $processes = [object[]]@()
        $tcp = [object[]]@()
        if ($calls -ge 2 -and $kind -ceq "process") {
            $processes = [object[]]@(
                [pscustomobject]@{
                    ProcessId = 4242
                    ExecutablePath = $serverExecutable
                }
            )
        }
        if ($calls -ge 2 -and $kind -ceq "listener") {
            $tcp = [object[]]@(
                [pscustomobject]@{
                    LocalPort = 65534
                    State = "Listen"
                }
            )
        }
        return [pscustomobject]@{
            cim_available = $true
            tcp_available = $true
            udp_available = $true
            processes = $processes
            tcp = $tcp
            udp = [object[]]@()
        }
    }.GetNewClosure()
} __KIND__ __SERVER_EXECUTABLE__
'@
    $result = $template.Replace(
        "__KIND__",
        (ConvertTo-CgceLifecycleSingleQuoted $Kind)
    )
    $result = $result.Replace(
        "__SERVER_EXECUTABLE__",
        (ConvertTo-CgceLifecycleSingleQuoted $Fixture.ServerExecutable)
    )
    return $result
}

Invoke-CgceTest "prepare pre-genesis failure matrix preserves active Saved bytes" {
    $cases = @(
        [pscustomobject]@{
            Name = "CLI/control path mismatch"
            Code = "CGCE-OPS-PATH"
            Setup = {
                param($Fixture)
                $otherServer = Join-Path $Fixture.Base "other-server"
                New-Item -ItemType Directory -Path $otherServer | Out-Null
                $Fixture.ServerRoot = $otherServer
            }
        },
        [pscustomobject]@{
            Name = "control checksum drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $text = [System.IO.File]::ReadAllText($Fixture.ControlPath)
                Write-CgceLifecycleUtf8 $Fixture.ControlPath ($text + " ")
            }
        },
        [pscustomobject]@{
            Name = "handoff manifest drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $text = [System.IO.File]::ReadAllText(
                    $Fixture.SourceManifestPath
                )
                Write-CgceLifecycleUtf8 `
                    $Fixture.SourceManifestPath `
                    ($text + ("f" * 64) + "  extra.txt`n")
            }
        },
        [pscustomobject]@{
            Name = "handoff payload drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $readme = Join-Path `
                    $Fixture.HandoffRoot `
                    "tools\windows-discovery\README.md"
                Write-CgceLifecycleUtf8 $readme "tampered handoff payload"
            }
        },
        [pscustomobject]@{
            Name = "UE4SS checksum drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    (Join-Path $Fixture.Ue4ssRoot "UE4SS.dll") `
                    "tampered synthetic UE4SS"
            }
        },
        [pscustomobject]@{
            Name = "unsupported UE4SS"
            Code = "CGCE-OPS-CONTROL"
            Setup = {
                param($Fixture)
                Update-CgceLifecycleControl $Fixture {
                    param($Control, $Ignored)
                    $Control.ue4ss_version = "3.0.2"
                }
            }
        },
        [pscustomobject]@{
            Name = "expired control evidence"
            Code = "CGCE-OPS-CONTROL-EXPIRED"
            Setup = {
                param($Fixture)
                Update-CgceLifecycleControl $Fixture {
                    param($Control, $Ignored)
                    $Control.verified_at_utc = "2020-01-01T00:00:00Z"
                    $Control.valid_until_utc = "2020-01-01T01:00:00Z"
                }
            }
        },
        [pscustomobject]@{
            Name = "Saved containment escape"
            Code = "CGCE-OPS-PATH"
            Setup = {
                param($Fixture)
                $escaped = Join-Path $Fixture.Base "outside\Saved"
                New-Item -ItemType Directory -Path $escaped -Force | Out-Null
                $Fixture.SavedPath = $escaped
            }
        },
        [pscustomobject]@{
            Name = "foreign active marker"
            Code = "CGCE-OPS-FOREIGN-ARTIFACT"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    $Fixture.Paths.active_run_marker `
                    "{}"
            }
        },
        [pscustomobject]@{
            Name = "foreign inactive original"
            Code = "CGCE-OPS-FOREIGN-ARTIFACT"
            Setup = {
                param($Fixture)
                $foreign = $Fixture.Paths.active_saved +
                    ".cgce-original-r-ffffffffffffffffffffffffffffffff"
                New-Item -ItemType Directory -Path $foreign | Out-Null
            }
        },
        [pscustomobject]@{
            Name = "existing inventory probe"
            Code = "CGCE-OPS-PROBE-EXISTS"
            Setup = {
                param($Fixture)
                New-Item `
                    -ItemType Directory `
                    -Path $Fixture.Paths.probe_staged |
                    Out-Null
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $null = & $case.Setup $fixture
            Assert-CgcePreparePreGenesisBlocked `
                -Fixture $fixture `
                -ExpectedCode $case.Code
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare post-genesis fault matrix blocks under the held lock" {
    $cases = @(
        [pscustomobject]@{
            Name = "backup publication"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "backup"
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.backup_saved
            }
        },
        [pscustomobject]@{
            Name = "state replace/read-back"
            Code = "CGCE-OPS-BACKUP"
            Phase = "BACKUP_VERIFIED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $true
            FailBlock = $false
            Fault = { param($Fixture) "" }
        },
        [pscustomobject]@{
            Name = "original rename"
            Code = "CGCE-OPS-COPY"
            Phase = "BACKUP_VERIFIED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "move-before" `
                    -Target $Fixture.Paths.inactive_original
            }
        },
        [pscustomobject]@{
            Name = "clone publication"
            Code = "CGCE-OPS-CLONE"
            Phase = "ORIGINAL_DEACTIVATED"
            OriginalLocation = "inactive"
            ActiveExpected = $false
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $true
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "active"
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.active_saved
            }
        },
        [pscustomobject]@{
            Name = "probe final receipt"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Phase = "CLONE_ACTIVE"
            OriginalLocation = "inactive"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $true
            CloneRecorded = $true
            ProbePrefixExpected = $true
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = { param($Fixture) New-CgceProbeFaultSetup }
        },
        [pscustomobject]@{
            Name = "blocked-state persistence"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "backup"
            FailState = $false
            FailBlock = $true
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.backup_saved
            }
        },
        [pscustomobject]@{
            Name = "PalServer drift"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-after-mutate" `
                    -Target $Fixture.Paths.backup_saved `
                    -MutationPath $Fixture.ServerExecutable
            }
        },
        [pscustomobject]@{
            Name = "UE4SS drift"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-after-mutate" `
                    -Target $Fixture.Paths.backup_saved `
                    -MutationPath $Fixture.Paths.ue4ss_dll
            }
        },
        [pscustomobject]@{
            Name = "process drift"
            Code = "CGCE-OPS-PROCESS-ACTIVE"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceActivityDriftSetup `
                    -Fixture $Fixture `
                    -Kind "process"
            }
        },
        [pscustomobject]@{
            Name = "listener drift"
            Code = "CGCE-OPS-PORT-ACTIVE"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceActivityDriftSetup `
                    -Fixture $Fixture `
                    -Kind "listener"
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $moduleSetup = (& $case.Fault $fixture) + "`r`n" +
                (New-CgcePersistenceFaultSetup `
                    -Fixture $fixture `
                    -FailAfterBackupState $case.FailState `
                    -FailBlockedPersistence $case.FailBlock)
            $result = Invoke-CgcePrepareChild `
                -Fixture $fixture `
                -ModuleSetup $moduleSetup
            Assert-CgceEqual $true ($result.ExitCode -ne 0)
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED $($case.Code) $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceEqual `
                $true `
                (Test-Path -LiteralPath (
                    Join-Path $fixture.Base "lock-held.txt"
                ) -PathType Leaf)
            $state = Read-CgceRunState `
                -RunRoot $fixture.RunRoot `
                -RunId $fixture.RunId
            Assert-CgceEqual $case.Phase $state.phase
            Assert-CgceEqual `
                $(if ($case.FailBlock) { "ACTIVE" } else { "BLOCKED" }) `
                $state.outcome
            if (-not $case.FailBlock) {
                Assert-CgceEqual $case.Code $state.errors[-1].code
            }
            Assert-CgceEqual `
                $case.ActiveExpected `
                (Test-Path -LiteralPath $fixture.Paths.active_saved -PathType Container)
            Assert-CgceEqual `
                $case.InactiveExpected `
                (Test-Path `
                    -LiteralPath $fixture.Paths.inactive_original `
                    -PathType Container)
            Assert-CgceEqual `
                $case.BackupDisk `
                (Test-Path `
                    -LiteralPath $fixture.Paths.backup_saved `
                    -PathType Container)
            Assert-CgceEqual `
                $case.BackupInventoryDisk `
                (Test-Path `
                    -LiteralPath $fixture.Paths.backup_inventory `
                    -PathType Leaf)
            Assert-CgceEqual `
                $case.BackupRecorded `
                ($null -ne $state.inventory_checksums.backup)
            Assert-CgceEqual `
                $case.CloneRecorded `
                ($null -ne $state.inventory_checksums.clone)
            Assert-CgceEqual `
                $case.CloneRecorded `
                (Test-Path `
                    -LiteralPath $fixture.Paths.clone_inventory `
                    -PathType Leaf)
            Assert-CgceEqual `
                $false `
                ($null -ne $state.probe_receipt_checksum)
            Assert-CgceEqual `
                $false `
                (Test-Path `
                    -LiteralPath $fixture.Paths.probe_receipt `
                    -PathType Leaf)
            $probePrefixCount = if (Test-Path `
                    -LiteralPath $fixture.Paths.probe_receipts `
                    -PathType Container) {
                @(Get-ChildItem `
                    -LiteralPath $fixture.Paths.probe_receipts `
                    -Force).Count
            } else {
                0
            }
            Assert-CgceEqual `
                $case.ProbePrefixExpected `
                ($probePrefixCount -gt 0)
            if ($case.BackupDisk) {
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.backup_saved)
            }
            if ($case.CloneRecorded) {
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.active_saved)
            }
            if (-not [string]::IsNullOrWhiteSpace($case.StagingTarget)) {
                $stagingDestination = if ($case.StagingTarget -ceq "backup") {
                    $fixture.Paths.backup_saved
                } else {
                    $fixture.Paths.active_saved
                }
                $stagingParent = Split-Path -Parent $stagingDestination
                $stagingLeaf = Split-Path -Leaf $stagingDestination
                $stagingEvidence = @(Get-ChildItem `
                        -LiteralPath $stagingParent `
                        -Filter ".$stagingLeaf.cgce-stage-tree-*" `
                        -Directory `
                        -Force)
                Assert-CgceEqual 1 $stagingEvidence.Count
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $stagingEvidence[0].FullName)
            }
            $originalPath = if ($case.OriginalLocation -ceq "active") {
                $fixture.Paths.active_saved
            } else {
                $fixture.Paths.inactive_original
            }
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory -Root $originalPath)
            Assert-CgceEqual `
                $fixture.SourceManifestSha `
                (Get-CgceSha256 $fixture.SourceManifestPath)
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare rejects a script executed outside the bound handoff tree with one line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.PrepareScript = $fixture.RepositoryPrepareScript
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.genesis_state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare keeps one terminal line when catch-path inspection throws" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fileFault = New-CgceFileFaultSetup `
            -Kind "tree-before" `
            -Target $fixture.Paths.backup_saved
        $testPathFault = @'
$global:CgceThrowStatePathProbe = $false
& $filesModule {
    $prior = $script:CgceTestPublishSeam
    $script:CgceTestPublishSeam = {
        param([string]$phase, $context)
        try {
            $null = & $prior $phase $context
        } catch {
            $global:CgceThrowStatePathProbe = $true
            throw
        }
    }.GetNewClosure()
}
function global:Test-Path {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,
        [Microsoft.PowerShell.Commands.TestPathType]$PathType =
            [Microsoft.PowerShell.Commands.TestPathType]::Any
    )
    if ($global:CgceThrowStatePathProbe -and
        $LiteralPath.EndsWith(
            "run-state.json",
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-TEST injected catch Test-Path fault"
    }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
'@
        $result = Invoke-CgcePrepareChild `
            -Fixture $fixture `
            -ModuleSetup ($fileFault + "`r`n" + $testPathFault)
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-BACKUP $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "CREATED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare keeps one blocked line when lock disposal throws" {
    $fixture = New-CgceSyntheticFixture
    try {
        $moduleSetup = @'
$global:CgceRealEnterLock = Get-Command `
    -Name "Enter-CgceExclusiveLock" `
    -CommandType Function
function global:Enter-CgceExclusiveLock {
    param([string]$ServerRoot, [string]$RunId)
    $inner = & $global:CgceRealEnterLock `
        -ServerRoot $ServerRoot `
        -RunId $RunId
    $fake = [pscustomobject]@{ Inner = $inner }
    $fake | Add-Member `
        -MemberType ScriptMethod `
        -Name "Dispose" `
        -Value {
            $this.Inner.Dispose()
            throw "CGCE-TEST injected Dispose fault"
        }
    return $fake
}
'@
        $result = Invoke-CgcePrepareChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-LOCK $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "PROBE_STAGED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects exact executable leaf reparse points before genesis" {
    $cases = @(
        [pscustomobject]@{
            Name = "PalServer executable"
            SelectPath = { param($Fixture) $Fixture.ServerExecutable }
        },
        [pscustomobject]@{
            Name = "UE4SS DLL"
            SelectPath = { param($Fixture) $Fixture.Paths.ue4ss_dll }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $leaf = & $case.SelectPath $fixture
            $target = Join-Path `
                $fixture.Base `
                ("same-bytes-" + [guid]::NewGuid().ToString("N"))
            [System.IO.File]::Copy($leaf, $target, $false)
            Remove-Item -LiteralPath $leaf -Force
            New-Item `
                -ItemType SymbolicLink `
                -Path $leaf `
                -Target $target |
                Out-Null
            Assert-CgcePreparePreGenesisBlocked `
                -Fixture $fixture `
                -ExpectedCode "CGCE-OPS-REPARSE"
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare preserves original and activates an equal clone with one terminal line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual 0 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_OK PROBE_STAGED $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
        Assert-CgceEqual "PROBE_STAGED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.inactive_original)
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.SavedPath)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.backup_saved)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.probe_receipt)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Assert-CgceEqual `
            $fixture.SourceManifestSha `
            (Get-CgceSha256 $fixture.SourceManifestPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects handoff and run-root overlap before genesis or production mutation" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.RunRoot = $fixture.HandoffRoot
        $fixture.Paths = New-CgceRunPaths `
            -ServerRoot $fixture.ServerRoot -SavedPath $fixture.SavedPath `
            -Ue4ssRoot $fixture.Ue4ssRoot -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PATH-OVERLAP $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.genesis_state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare renders a CRLF-bearing invalid run id as one safe terminal line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.RunId = "bad`r`ninjected"
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-ID INVALID_RUN_ID" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare replay rejects the existing final run directory without another mutation" {
    $fixture = New-CgceSyntheticFixture
    try {
        $first = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual 0 $first.ExitCode
        $activeBefore = @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        $inactiveBefore = @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)

        $second = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual 1 @($second.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-STATE-EXISTS $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Compare-CgceInventory `
            -Expected $activeBefore `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Compare-CgceInventory `
            -Expected $inactiveBefore `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}
