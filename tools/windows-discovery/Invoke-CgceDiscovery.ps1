#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$ServerExecutable,
    [Parameter(Mandatory = $true)]
    [string]$ArgumentsPath,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-CgceInvokeErrorCode($ErrorRecord) {
    $message = ""
    try {
        if ($null -ne $ErrorRecord -and
            $null -ne $ErrorRecord.Exception) {
            $message = [string]$ErrorRecord.Exception.Message
        }
    } catch {
        $message = ""
    }
    $match = [regex]::Match(
        $message,
        '^\s*(CGCE-OPS-[A-Z0-9-]+)(?![A-Za-z0-9-])'
    )
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return "CGCE-OPS-BLOCKED"
}

function Close-CgceInvokeLock($Lock) {
    if ($null -eq $Lock) {
        return $true
    }
    try {
        $Lock.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Get-CgceInvokeBootstrapCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "CGCE-OPS-CHECKSUM bootstrap path is required"
    }
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        throw "CGCE-OPS-CHECKSUM invalid bootstrap path"
    }
}

function Assert-CgceInvokeBootstrapNoReparse([string]$Path) {
    $current = Get-CgceInvokeBootstrapCanonicalPath $Path
    $volumeRoot = [System.IO.Path]::GetPathRoot($current).TrimEnd('\', '/')
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ($current.Equals(
                $volumeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            break
        }
        try {
            $item = Get-Item -LiteralPath $current -Force
        } catch {
            throw "CGCE-OPS-CHECKSUM bootstrap path is missing"
        }
        if (($item.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CGCE-OPS-CHECKSUM bootstrap reparse point is forbidden"
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals(
                $current,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            break
        }
        $current = $parent.TrimEnd('\', '/')
    }
}

function Assert-CgceInvokeBootstrapDistinct(
    [string]$First,
    [string]$Second
) {
    $left = Get-CgceInvokeBootstrapCanonicalPath $First
    $right = Get-CgceInvokeBootstrapCanonicalPath $Second
    $leftPrefix = $left + "\"
    $rightPrefix = $right + "\"
    if ($left.Equals($right, [StringComparison]::OrdinalIgnoreCase) -or
        $left.StartsWith(
            $rightPrefix,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $right.StartsWith(
            $leftPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-PATH-OVERLAP handoff and run root overlap"
    }
}

function Get-CgceInvokeBootstrapSha256(
    [string]$Path,
    [int]$MaxBytes = 0
) {
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $algorithm = [System.Security.Cryptography.SHA256]::Create()
            try {
                if ($MaxBytes -gt 0) {
                    $length = [int64]$stream.Length
                    if ($length -lt 1 -or $length -gt $MaxBytes) {
                        throw "CGCE-OPS-CHECKSUM bootstrap authority size is invalid"
                    }
                    $bytes = New-Object byte[] ([int]$length)
                    $offset = 0
                    while ($offset -lt $bytes.Length) {
                        $read = $stream.Read(
                            $bytes,
                            $offset,
                            $bytes.Length - $offset
                        )
                        if ($read -le 0) {
                            throw "CGCE-OPS-CHECKSUM bootstrap authority truncated"
                        }
                        $offset += $read
                    }
                    if ($stream.ReadByte() -ne -1 -or
                        [int64]$stream.Length -ne $length) {
                        throw "CGCE-OPS-CHECKSUM bootstrap authority changed during read"
                    }
                    $hash = $algorithm.ComputeHash($bytes)
                } else {
                    $hash = $algorithm.ComputeHash($stream)
                }
                return ([BitConverter]::ToString(
                    $hash
                )).Replace("-", "").ToLowerInvariant()
            } finally {
                $algorithm.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        if ($_.Exception.Message.StartsWith(
                "CGCE-OPS-",
                [StringComparison]::Ordinal
            )) {
            throw
        }
        throw "CGCE-OPS-CHECKSUM bootstrap checksum failed"
    }
}

function Read-CgceInvokeBootstrapUtf8(
    [string]$Path,
    [int]$MaxBytes
) {
    Assert-CgceInvokeBootstrapNoReparse $Path
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $length = [int64]$stream.Length
        if ($length -lt 1 -or $length -gt $MaxBytes) {
            throw "CGCE-OPS-CHECKSUM bootstrap authority size is invalid"
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read(
                $bytes,
                $offset,
                $bytes.Length - $offset
            )
            if ($read -le 0) {
                throw "CGCE-OPS-CHECKSUM bootstrap authority truncated"
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1 -or
            [int64]$stream.Length -ne $length) {
            throw "CGCE-OPS-CHECKSUM bootstrap authority changed during read"
        }
    } catch {
        if ($_.Exception.Message.StartsWith(
                "CGCE-OPS-",
                [StringComparison]::Ordinal
            )) {
            throw
        }
        throw "CGCE-OPS-CHECKSUM bootstrap authority is unreadable"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        throw "CGCE-OPS-CHECKSUM bootstrap UTF-8 BOM is forbidden"
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        return $encoding.GetString($bytes)
    } catch {
        throw "CGCE-OPS-CHECKSUM bootstrap UTF-8 is invalid"
    }
}

function Read-CgceInvokeGenesisManifestChecksum(
    [string]$GenesisPath
) {
    $text = Read-CgceInvokeBootstrapUtf8 `
        -Path $GenesisPath `
        -MaxBytes 1048576
    $keyMatches = [regex]::Matches(
        $text,
        '"source_manifest_checksum"\s*:',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $valueMatches = [regex]::Matches(
        $text,
        '"source_manifest_checksum"\s*:\s*"([0-9a-f]{64})"'
    )
    if ($keyMatches.Count -ne 1 -or $valueMatches.Count -ne 1) {
        throw "CGCE-OPS-CHECKSUM invalid genesis manifest authority"
    }
    try {
        $value = $text | ConvertFrom-Json
    } catch {
        throw "CGCE-OPS-CHECKSUM invalid genesis JSON"
    }
    if ($null -eq $value -or
        $value -is [System.Array] -or
        $null -eq $value.PSObject.Properties[
            "source_manifest_checksum"
        ] -or
        [string]$value.source_manifest_checksum -cne
            $valueMatches[0].Groups[1].Value) {
        throw "CGCE-OPS-CHECKSUM invalid genesis manifest authority"
    }
    return $valueMatches[0].Groups[1].Value
}

function Read-CgceInvokeBootstrapManifest([string]$ManifestPath) {
    $text = Read-CgceInvokeBootstrapUtf8 `
        -Path $ManifestPath `
        -MaxBytes 1048576
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal) -or
        $text.Contains("`r")) {
        throw "CGCE-OPS-CHECKSUM invalid bootstrap manifest lines"
    }
    $records = @{}
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
    $previous = $null
    foreach ($line in $lines) {
        $match = [regex]::Match(
            $line,
            '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)\z'
        )
        if (-not $match.Success) {
            throw "CGCE-OPS-CHECKSUM invalid bootstrap manifest record"
        }
        $relative = $match.Groups[2].Value
        if ($records.ContainsKey($relative) -or
            ($null -ne $previous -and
                [string]::CompareOrdinal($previous, $relative) -ge 0)) {
            throw "CGCE-OPS-CHECKSUM invalid bootstrap manifest order"
        }
        $records[$relative] = $match.Groups[1].Value
        $previous = $relative
    }
    return $records
}

function Get-CgceInvokeBootstrap(
    [string]$ScriptRoot,
    [string]$ScriptPath,
    [string]$BoundRunRoot,
    [string]$BoundRunId
) {
    if ($BoundRunId -cnotmatch '^r-[0-9a-f]{32}\z') {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $actualRoot = Get-CgceInvokeBootstrapCanonicalPath $ScriptRoot
    $handoffRoot = Get-CgceInvokeBootstrapCanonicalPath (
        Join-Path $actualRoot "..\.."
    )
    $expectedRoot = Get-CgceInvokeBootstrapCanonicalPath (
        Join-Path $handoffRoot "tools\windows-discovery"
    )
    $actualScript = Get-CgceInvokeBootstrapCanonicalPath $ScriptPath
    $expectedScript = Get-CgceInvokeBootstrapCanonicalPath (
        Join-Path $expectedRoot "Invoke-CgceDiscovery.ps1"
    )
    if (-not $actualRoot.Equals(
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $actualScript.Equals(
            $expectedScript,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM invoke script is outside handoff tree"
    }
    Assert-CgceInvokeBootstrapNoReparse $handoffRoot
    Assert-CgceInvokeBootstrapNoReparse $actualScript
    Assert-CgceInvokeBootstrapDistinct $handoffRoot $BoundRunRoot

    $runRootPath = Get-CgceInvokeBootstrapCanonicalPath $BoundRunRoot
    Assert-CgceInvokeBootstrapNoReparse $runRootPath
    $genesisPath = Join-Path `
        (Join-Path $runRootPath $BoundRunId) `
        "run-state.genesis.json"
    $manifestPath = Join-Path $handoffRoot "source-manifest.sha256"
    Assert-CgceInvokeBootstrapNoReparse $manifestPath
    $expectedManifestChecksum =
        Read-CgceInvokeGenesisManifestChecksum $genesisPath
    $actualManifestChecksum = Get-CgceInvokeBootstrapSha256 `
        -Path $manifestPath `
        -MaxBytes 1048576
    if ($actualManifestChecksum -cne $expectedManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }

    $manifest = Read-CgceInvokeBootstrapManifest $manifestPath
    $trustedLeaves = [ordered]@{
        invoke =
            "tools/windows-discovery/Invoke-CgceDiscovery.ps1"
        common =
            "tools/windows-discovery/CgceDiscovery.Common.psm1"
        contract =
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1"
        files =
            "tools/windows-discovery/modules/CgceDiscovery.Files.psm1"
        runtime =
            "tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1"
    }
    $resolved = [ordered]@{}
    foreach ($name in $trustedLeaves.Keys) {
        $relative = $trustedLeaves[$name]
        if (-not $manifest.ContainsKey($relative)) {
            throw "CGCE-OPS-CHECKSUM bootstrap manifest leaf missing"
        }
        $leaf = Get-CgceInvokeBootstrapCanonicalPath (
            Join-Path $handoffRoot ($relative -replace '/', '\')
        )
        Assert-CgceInvokeBootstrapNoReparse $leaf
        if ((Get-CgceInvokeBootstrapSha256 $leaf) -cne
            $manifest[$relative]) {
            throw "CGCE-OPS-CHECKSUM bootstrap payload drift"
        }
        $resolved[$name] = $leaf
    }
    return [pscustomobject]@{
        handoff_root = $handoffRoot
        manifest_path = $manifestPath
        manifest_checksum = $actualManifestChecksum
        script_root = $actualRoot
        script_path = $actualScript
        common_module = $resolved.common
        contract_module = $resolved.contract
        files_module = $resolved.files
        runtime_module = $resolved.runtime
    }
}

function Import-CgceInvokeVerifiedModule(
    [string]$Path,
    [string]$Name
) {
    $expected = Get-CgceInvokeBootstrapCanonicalPath $Path
    $matching = $null
    foreach ($module in @(Get-Module -Name $Name -All)) {
        $actual = Get-CgceInvokeBootstrapCanonicalPath $module.Path
        if (-not $actual.Equals(
                $expected,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "CGCE-OPS-CHECKSUM preloaded module origin drift"
        }
        $matching = $module
    }
    if ($null -eq $matching) {
        Import-Module $expected -Scope Global | Out-Null
    }
    $loaded = @(
        Get-Module -Name $Name -All |
            Where-Object {
                (Get-CgceInvokeBootstrapCanonicalPath $_.Path).Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($loaded.Count -ne 1) {
        throw "CGCE-OPS-CHECKSUM verified module did not load exactly once"
    }
}

function Assert-CgceInvokeControlBinding($State, $Control) {
    if ($Control.run_id -cne $State.run_id -or
        $Control.maintenance_id -cne $State.maintenance_id -or
        $Control.bundle_checksum -cne $State.bundle_checksum -or
        $Control.ue4ss_version -cne $State.ue4ss_version -or
        $Control.ue4ss_dll_sha256 -cne $State.ue4ss_dll_checksum -or
        [string]::Join(
            "`n",
            [string[]]@($Control.server_process_paths)
        ) -cne [string]::Join(
            "`n",
            [string[]]@($State.server_process_paths)
        ) -or
        [string]::Join(
            ",",
            [string[]]@($Control.listener_ports)
        ) -cne [string]::Join(
            ",",
            [string[]]@($State.listener_ports)
        )) {
        throw "CGCE-OPS-CONTROL control/state binding drift"
    }
    Assert-CgceEqualCanonicalPath `
        -Expected $State.paths.server_root `
        -Actual $Control.server_root
    Assert-CgceEqualCanonicalPath `
        -Expected $State.palserver_executable `
        -Actual $Control.palserver_executable
    Assert-CgceEqualCanonicalPath `
        -Expected $State.paths.ue4ss_root `
        -Actual $Control.ue4ss_root
}

function Assert-CgceInvokePreparedInventories($State) {
    foreach ($binding in @(
        [pscustomobject]@{
            Path = $State.paths.original_inventory
            Checksum = $State.inventory_checksums.original
        },
        [pscustomobject]@{
            Path = $State.paths.backup_inventory
            Checksum = $State.inventory_checksums.backup
        },
        [pscustomobject]@{
            Path = $State.paths.clone_inventory
            Checksum = $State.inventory_checksums.clone
        }
    )) {
        if ((Get-CgceSha256 -Path $binding.Path) -cne
            $binding.Checksum) {
            throw "CGCE-OPS-CHECKSUM prepared inventory file drift"
        }
    }
    $original = @(
        Read-CgceInventory `
            -Path $State.paths.original_inventory `
            -ExpectedKind "original"
    )
    $backup = @(
        Read-CgceInventory `
            -Path $State.paths.backup_inventory `
            -ExpectedKind "backup"
    )
    $clone = @(
        Read-CgceInventory `
            -Path $State.paths.clone_inventory `
            -ExpectedKind "clone"
    )
    Compare-CgceInventory -Expected $original -Actual $backup
    Compare-CgceInventory -Expected $original -Actual $clone
    Compare-CgceInventory `
        -Expected $original `
        -Actual @(Get-CgceTreeInventory `
            -Root $State.paths.inactive_original)
    Compare-CgceInventory `
        -Expected $original `
        -Actual @(Get-CgceTreeInventory `
            -Root $State.paths.backup_saved)
    Compare-CgceInventory `
        -Expected $original `
        -Actual @(Get-CgceTreeInventory `
            -Root $State.paths.active_saved)
}

function Assert-CgceInvokePreservedOriginal($State) {
    foreach ($binding in @(
        [pscustomobject]@{
            Path = $State.paths.original_inventory
            Checksum = $State.inventory_checksums.original
        },
        [pscustomobject]@{
            Path = $State.paths.backup_inventory
            Checksum = $State.inventory_checksums.backup
        },
        [pscustomobject]@{
            Path = $State.paths.clone_inventory
            Checksum = $State.inventory_checksums.clone
        }
    )) {
        if ((Get-CgceSha256 -Path $binding.Path) -cne
            $binding.Checksum) {
            throw "CGCE-OPS-CHECKSUM preserved inventory file drift"
        }
    }
    $original = @(
        Read-CgceInventory `
            -Path $State.paths.original_inventory `
            -ExpectedKind "original"
    )
    $backup = @(
        Read-CgceInventory `
            -Path $State.paths.backup_inventory `
            -ExpectedKind "backup"
    )
    $null = @(
        Read-CgceInventory `
            -Path $State.paths.clone_inventory `
            -ExpectedKind "clone"
    )
    Compare-CgceInventory -Expected $original -Actual $backup
    Compare-CgceInventory `
        -Expected $original `
        -Actual @(Get-CgceTreeInventory `
            -Root $State.paths.inactive_original)
    Compare-CgceInventory `
        -Expected $original `
        -Actual @(Get-CgceTreeInventory `
            -Root $State.paths.backup_saved)
}

function Assert-CgceInvokeCaptureSource($State) {
    Assert-CgceNoReparseInPath -Path $State.paths.object_dump
    Assert-CgceNoReparseInPath -Path $State.paths.cxx_header_dump
    Assert-CgceNoReparseInPath -Path $State.paths.ue4ss_log
    if (-not (Test-Path `
            -LiteralPath $State.paths.object_dump `
            -PathType Leaf) -or
        (Get-Item -LiteralPath $State.paths.object_dump).Length -le 0) {
        throw "CGCE-OPS-CAPTURE-MISSING object dump missing or empty"
    }
    if (-not (Test-Path `
            -LiteralPath $State.paths.cxx_header_dump `
            -PathType Container)) {
        throw "CGCE-OPS-CAPTURE-MISSING CXX header dump missing"
    }
    Assert-CgceTreeHasNoReparsePoints -Root $State.paths.cxx_header_dump
    $headers = @(Get-CgceTreeInventory `
        -Root $State.paths.cxx_header_dump)
    if ($headers.Count -lt 1) {
        throw "CGCE-OPS-CAPTURE-MISSING CXX header dump is empty"
    }
    if (-not (Test-Path `
            -LiteralPath $State.paths.ue4ss_log `
            -PathType Leaf)) {
        throw "CGCE-OPS-CAPTURE-MISSING UE4SS log missing"
    }
    $logInfo = Get-Item -LiteralPath $State.paths.ue4ss_log
    if ($logInfo.Length -lt 1 -or $logInfo.Length -gt 16777216) {
        throw "CGCE-OPS-CAPTURE-MISSING UE4SS log size invalid"
    }
    try {
        $lines = [System.IO.File]::ReadAllLines($State.paths.ue4ss_log)
    } catch {
        throw "CGCE-OPS-CAPTURE-MISSING UE4SS log unreadable"
    }
    $complete = 0
    foreach ($line in $lines) {
        $complete += [regex]::Matches(
            $line,
            'CGCE_INVENTORY_COMPLETE ALL'
        ).Count
        if ($line.Contains("CGCE_INVENTORY_BLOCKED")) {
            throw "CGCE-OPS-CAPTURE-MISSING probe reported blocked"
        }
    }
    if ($complete -ne 1) {
        throw "CGCE-OPS-CAPTURE-MISSING exact completion marker required"
    }
}

function Assert-CgceInvokeEmptyDirectory(
    [string]$Path,
    [string]$Code
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or
        @(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw "$Code directory must be empty"
    }
}

function Assert-CgceInvokePreLaunchAuthority(
    $Bootstrap,
    [string]$BoundRunRoot,
    [string]$BoundRunId,
    [string]$ExpectedExecutable,
    [string]$LaunchReceiptChecksum
) {
    $fresh = Read-CgceRunState `
        -RunRoot $BoundRunRoot `
        -RunId $BoundRunId
    if ($fresh.phase -cne "RUNNING" -or
        $fresh.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE pre-launch authority requires active RUNNING"
    }
    Assert-CgceRunMarker -State $fresh
    if ($fresh.source_manifest_checksum -cne
        $Bootstrap.manifest_checksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }
    $null = Assert-CgceInventoryProbeStaged `
        -Paths $fresh.paths `
        -RunDirectory $fresh.paths.run_directory `
        -RunId $BoundRunId `
        -ExpectedFinalReceiptChecksum $fresh.probe_receipt_checksum `
        -ExpectedLaunchReceiptChecksum $LaunchReceiptChecksum
    $control = Assert-CgceControlEvidence `
        -EvidencePath $fresh.paths.control_evidence `
        -ExpectedFileChecksum $fresh.control_evidence_checksum `
        -ExpectedBundleChecksum $fresh.bundle_checksum `
        -NowUtc ([DateTime]::UtcNow)
    Assert-CgceInvokeControlBinding -State $fresh -Control $control
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($fresh.server_process_paths)) `
        -Ports ([int[]]@($fresh.listener_ports)) `
        -ReceiptRoot $fresh.paths.process_receipts
    Assert-CgceInvokePreparedInventories -State $fresh
    Assert-CgceEqualCanonicalPath `
        -Expected $fresh.palserver_executable `
        -Actual $ExpectedExecutable
    Assert-CgceNoReparseInPath -Path $ExpectedExecutable
    Assert-CgceNoReparseInPath -Path $fresh.paths.ue4ss_dll
    if ((Get-CgceSha256 -Path $ExpectedExecutable) -cne
            $fresh.palserver_executable_checksum -or
        (Get-CgceSha256 -Path $fresh.paths.ue4ss_dll) -cne
            $fresh.ue4ss_dll_checksum) {
        throw "CGCE-OPS-CHECKSUM launch-bound executable drift"
    }
    Assert-CgceHandoffSource `
        -HandoffRoot $Bootstrap.handoff_root `
        -ManifestPath $Bootstrap.manifest_path `
        -ExpectedManifestChecksum $fresh.source_manifest_checksum
}

function Invoke-CgceSafeInvokeBlock(
    [bool]$ModulesReady,
    [bool]$LockHeld,
    [string]$BoundRunRoot,
    [string]$BoundRunId,
    [string]$Code
) {
    if (-not $ModulesReady -or -not $LockHeld) {
        return
    }
    try {
        $state = Read-CgceRunState `
            -RunRoot $BoundRunRoot `
            -RunId $BoundRunId
        if ($state.outcome -ceq "ACTIVE" -and
            @("PROBE_STAGED", "RUNNING") -ccontains $state.phase) {
            $null = Block-CgceRunState `
                -StatePath $state.paths.state `
                -Code $Code
        }
    } catch {
        # Preserve the original failure and any immutable partial evidence.
    }
}

$lock = $null
$modulesReady = $false
$lockHeld = $false
$terminalPhase = $null
$terminalCode = $null
$terminalRunId = "INVALID_RUN_ID"
$exitCode = 1

try {
    if ($RunId -cmatch '^r-[0-9a-f]{32}\z') {
        $terminalRunId = $RunId
    }
    $bootstrap = Get-CgceInvokeBootstrap `
        -ScriptRoot $PSScriptRoot `
        -ScriptPath $MyInvocation.MyCommand.Path `
        -BoundRunRoot $RunRoot `
        -BoundRunId $RunId
    Import-CgceInvokeVerifiedModule `
        -Path $bootstrap.contract_module `
        -Name "CgceDiscovery.Contract"
    Import-CgceInvokeVerifiedModule `
        -Path $bootstrap.files_module `
        -Name "CgceDiscovery.Files"
    Import-CgceInvokeVerifiedModule `
        -Path $bootstrap.runtime_module `
        -Name "CgceDiscovery.Runtime"
    Import-CgceInvokeVerifiedModule `
        -Path $bootstrap.common_module `
        -Name "CgceDiscovery.Common"
    $modulesReady = $true

    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $terminalRunId = $RunId
    Assert-CgceHandoffSource `
        -HandoffRoot $bootstrap.handoff_root `
        -ManifestPath $bootstrap.manifest_path `
        -ExpectedManifestChecksum $bootstrap.manifest_checksum
    if ((Get-CgceSha256 -Path $bootstrap.manifest_path) -cne
        $bootstrap.manifest_checksum) {
        throw "CGCE-OPS-CHECKSUM source manifest changed during bootstrap"
    }

    $provisional = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    $lockRoot = $provisional.paths.server_root
    $lock = Enter-CgceExclusiveLock `
        -ServerRoot $lockRoot `
        -RunId $RunId
    $lockHeld = $true

    $state = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    Assert-CgceEqualCanonicalPath `
        -Expected $lockRoot `
        -Actual $state.paths.server_root
    if ($state.source_manifest_checksum -cne
        $bootstrap.manifest_checksum) {
        throw "CGCE-OPS-CHECKSUM state/source manifest drift"
    }
    if ($state.phase -cne "PROBE_STAGED" -or
        $state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE invoke requires active PROBE_STAGED"
    }
    Assert-CgceRunMarker -State $state
    Assert-CgceDistinctRoots -Paths @(
        $bootstrap.handoff_root,
        $state.paths.run_root
    )
    Assert-CgceEqualCanonicalPath `
        -Expected $state.palserver_executable `
        -Actual $ServerExecutable
    Assert-CgceNoReparseInPath -Path $ServerExecutable
    Assert-CgceNoReparseInPath -Path $state.paths.ue4ss_dll
    if ((Get-CgceSha256 -Path $ServerExecutable) -cne
        $state.palserver_executable_checksum) {
        throw "CGCE-OPS-CHECKSUM PalServer executable drift"
    }
    if ((Get-CgceSha256 -Path $state.paths.ue4ss_dll) -cne
        $state.ue4ss_dll_checksum) {
        throw "CGCE-OPS-CHECKSUM UE4SS DLL drift"
    }
    Assert-CgceInvokePreparedInventories -State $state
    $null = Assert-CgceInventoryProbeStaged `
        -Paths $state.paths `
        -RunDirectory $state.paths.run_directory `
        -RunId $RunId `
        -ExpectedFinalReceiptChecksum $state.probe_receipt_checksum
    Assert-CgceInvokeEmptyDirectory `
        -Path $state.paths.capture `
        -Code "CGCE-OPS-CAPTURE"
    Assert-CgceInvokeEmptyDirectory `
        -Path $state.paths.process_receipts `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    Assert-CgceInvokeEmptyDirectory `
        -Path $state.paths.restore_receipts `
        -Code "CGCE-OPS-MANUAL-RECOVERY"

    $arguments = Read-CgceJsonStringArray -Path $ArgumentsPath
    if ($arguments -isnot [string[]]) {
        throw "CGCE-OPS-ARGUMENT exact string array required"
    }
    Assert-CgceServerArguments -Arguments $arguments
    $control = Assert-CgceControlEvidence `
        -EvidencePath $state.paths.control_evidence `
        -ExpectedFileChecksum $state.control_evidence_checksum `
        -ExpectedBundleChecksum $state.bundle_checksum `
        -NowUtc ([DateTime]::UtcNow)
    Assert-CgceInvokeControlBinding -State $state -Control $control
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($state.server_process_paths)) `
        -Ports ([int[]]@($state.listener_ports)) `
        -ReceiptRoot $state.paths.process_receipts
    Assert-CgceHandoffSource `
        -HandoffRoot $bootstrap.handoff_root `
        -ManifestPath $bootstrap.manifest_path `
        -ExpectedManifestChecksum $state.source_manifest_checksum

    $state = Set-CgceRunPhase `
        -State $state `
        -ExpectedPhase "PROBE_STAGED" `
        -NextPhase "RUNNING"
    Write-CgceRunState `
        -State $state `
        -StatePath $state.paths.state `
        -ExpectedPhase "PROBE_STAGED"
    $state = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    Assert-CgceRunMarker -State $state
    Assert-CgceHandoffSource `
        -HandoffRoot $bootstrap.handoff_root `
        -ManifestPath $bootstrap.manifest_path `
        -ExpectedManifestChecksum $state.source_manifest_checksum

    $controlValidUntil = [DateTime]::ParseExact(
        $control.valid_until_utc,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
    $preLaunchValidation = {
        param($LaunchReceiptChecksum)
        Assert-CgceInvokePreLaunchAuthority `
            -Bootstrap $bootstrap `
            -BoundRunRoot $RunRoot `
            -BoundRunId $RunId `
            -ExpectedExecutable $ServerExecutable `
            -LaunchReceiptChecksum $LaunchReceiptChecksum
    }.GetNewClosure()
    $processRun = Invoke-CgceChildProcess `
        -Executable $ServerExecutable `
        -ExpectedExecutableChecksum $state.palserver_executable_checksum `
        -AllowedExecutablePaths ([string[]]@($state.server_process_paths)) `
        -Arguments ([string[]]$arguments) `
        -ReceiptRoot $state.paths.process_receipts `
        -TimeoutSeconds $TimeoutSeconds `
        -ControlValidUntilUtc $controlValidUntil `
        -PreLaunchValidation $preLaunchValidation
    if ([int]$processRun.result.exit_code -ne 0) {
        throw "CGCE-OPS-PROCESS-EXIT non-zero child exit"
    }

    $control = Assert-CgceControlEvidence `
        -EvidencePath $state.paths.control_evidence `
        -ExpectedFileChecksum $state.control_evidence_checksum `
        -ExpectedBundleChecksum $state.bundle_checksum `
        -NowUtc ([DateTime]::UtcNow)
    Assert-CgceInvokeControlBinding -State $state -Control $control
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($state.server_process_paths)) `
        -Ports ([int[]]@($state.listener_ports)) `
        -ReceiptRoot $state.paths.process_receipts
    Assert-CgceInvokePreservedOriginal -State $state
    Assert-CgceInvokeCaptureSource -State $state
    Assert-CgceInvokeEmptyDirectory `
        -Path $state.paths.capture `
        -Code "CGCE-OPS-CAPTURE"

    $null = Copy-CgceFileVerified `
        -Source $state.paths.object_dump `
        -Destination (Join-Path `
            $state.paths.capture `
            "UE4SS_ObjectDump.txt")
    $null = @(
        Copy-CgceTreeVerified `
            -Source $state.paths.cxx_header_dump `
            -Destination (Join-Path `
                $state.paths.capture `
                "CXXHeaderDump")
    )
    $captureChildren = @(
        Get-ChildItem -LiteralPath $state.paths.capture -Force
    )
    if ($captureChildren.Count -ne 2 -or
        -not (Test-Path `
            -LiteralPath (Join-Path `
                $state.paths.capture `
                "UE4SS_ObjectDump.txt") `
            -PathType Leaf) -or
        -not (Test-Path `
            -LiteralPath (Join-Path `
                $state.paths.capture `
                "CXXHeaderDump") `
            -PathType Container)) {
        throw "CGCE-OPS-CAPTURE exact capture shape required"
    }
    $captureInventory = @(
        Get-CgceTreeInventory -Root $state.paths.capture
    )
    $captureChecksum = Write-CgceInventory `
        -Entries $captureInventory `
        -Path $state.paths.capture_inventory `
        -Kind "capture"
    if ((Get-CgceSha256 -Path $state.paths.process_launch_receipt) -cne
            $processRun.launch_receipt_checksum -or
        (Get-CgceSha256 -Path $state.paths.process_result_receipt) -cne
            $processRun.result_receipt_checksum) {
        throw "CGCE-OPS-CHECKSUM process receipt drift"
    }
    $state = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    if ($state.phase -cne "RUNNING" -or
        $state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE invoke state drift before capture commit"
    }
    Assert-CgceInvokePreservedOriginal -State $state
    $state.process_launch_receipt_checksum =
        $processRun.launch_receipt_checksum
    $state.process_result_receipt_checksum =
        $processRun.result_receipt_checksum
    $state.capture_inventory_checksum = $captureChecksum
    $state = Set-CgceRunPhase `
        -State $state `
        -ExpectedPhase "RUNNING" `
        -NextPhase "CAPTURED"
    Write-CgceRunState `
        -State $state `
        -StatePath $state.paths.state `
        -ExpectedPhase "RUNNING"
    $state = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    $terminalPhase = $state.phase
    $exitCode = 0
} catch {
    $terminalCode = Get-CgceInvokeErrorCode $_
    Invoke-CgceSafeInvokeBlock `
        -ModulesReady $modulesReady `
        -LockHeld $lockHeld `
        -BoundRunRoot $RunRoot `
        -BoundRunId $RunId `
        -Code $terminalCode
} finally {
    if (-not (Close-CgceInvokeLock -Lock $lock)) {
        $exitCode = 1
        if ([string]::IsNullOrWhiteSpace($terminalCode)) {
            $terminalCode = "CGCE-OPS-LOCK"
        }
    }
}

if ($exitCode -eq 0) {
    Write-Output "CGCE_WINDOWS_DISCOVERY_OK $terminalPhase $terminalRunId"
} else {
    if ([string]::IsNullOrWhiteSpace($terminalCode)) {
        $terminalCode = "CGCE-OPS-BLOCKED"
    }
    Write-Output "CGCE_WINDOWS_DISCOVERY_BLOCKED $terminalCode $terminalRunId"
}
exit $exitCode
