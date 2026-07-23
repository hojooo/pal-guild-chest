#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerRoot,
    [Parameter(Mandatory = $true)]
    [string]$SavedPath,
    [Parameter(Mandatory = $true)]
    [string]$Ue4ssRoot,
    [Parameter(Mandatory = $true)]
    [string]$ServerExecutable,
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$HandoffRoot,
    [Parameter(Mandatory = $true)]
    [string]$SourceManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$ControlEvidencePath,
    [Parameter(Mandatory = $true)]
    [string]$ControlEvidenceSha256,
    [Parameter(Mandatory = $true)]
    [string]$BundleSha256
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-CgcePrepareErrorCode([string]$Message) {
    $match = [regex]::Match(
        $Message,
        '^\s*(CGCE-OPS-[A-Z0-9-]+)(?![A-Za-z0-9-])'
    )
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return "CGCE-OPS-BLOCKED"
}

function Invoke-CgceSafeBlockAttempt(
    [bool]$StateAuthorityCreated,
    $Paths,
    [string]$Code
) {
    try {
        if (-not $StateAuthorityCreated -or $null -eq $Paths) {
            return
        }
        if (-not (Test-Path -LiteralPath $Paths.state -PathType Leaf) -or
            -not (Test-Path -LiteralPath $Paths.genesis_state -PathType Leaf) -or
            -not (Test-Path -LiteralPath $Paths.active_run_marker -PathType Leaf)) {
            return
        }
        $null = Block-CgceRunState `
            -StatePath $Paths.state `
            -Code $Code
    } catch {
        # Preserve invalid authority for manual recovery without masking the
        # single terminal protocol line.
    }
}

function Close-CgcePrepareLock($Lock) {
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

function Get-CgceBootstrapCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "CGCE-OPS-CHECKSUM bootstrap path is required"
    }
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        throw "CGCE-OPS-CHECKSUM invalid bootstrap path"
    }
}

function Assert-CgceBootstrapNoReparse([string]$Path) {
    $current = Get-CgceBootstrapCanonicalPath $Path
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
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CGCE-OPS-CHECKSUM bootstrap reparse point is forbidden"
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent.TrimEnd('\', '/')
    }
}

function Assert-CgceBootstrapTree(
    [string]$ScriptRoot,
    [string]$ScriptPath,
    [string]$BoundHandoffRoot
) {
    $handoff = Get-CgceBootstrapCanonicalPath $BoundHandoffRoot
    $expected = Get-CgceBootstrapCanonicalPath (
        Join-Path $handoff "tools\windows-discovery"
    )
    $actual = Get-CgceBootstrapCanonicalPath $ScriptRoot
    if (-not $actual.Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM prepare script is outside handoff tree"
    }
    $expectedScript = Get-CgceBootstrapCanonicalPath (
        Join-Path $expected "Prepare-CgceDiscovery.ps1"
    )
    $actualScript = Get-CgceBootstrapCanonicalPath $ScriptPath
    if (-not $actualScript.Equals(
            $expectedScript,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM prepare script leaf identity drift"
    }
    Assert-CgceBootstrapNoReparse $handoff
    Assert-CgceBootstrapNoReparse $actual
    Assert-CgceBootstrapNoReparse $actualScript
    return [pscustomobject]@{
        handoff_root = $handoff
        script_root = $actual
        script_path = $actualScript
    }
}

function Assert-CgceBootstrapLeaf(
    [string]$VerifiedScriptRoot,
    [string]$RelativePath
) {
    $leaf = Get-CgceBootstrapCanonicalPath (
        Join-Path $VerifiedScriptRoot $RelativePath
    )
    $prefix = $VerifiedScriptRoot.TrimEnd('\', '/') + "\"
    if (-not $leaf.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM bootstrap leaf escapes handoff tree"
    }
    try {
        $isLeaf = Test-Path -LiteralPath $leaf -PathType Leaf
    } catch {
        throw "CGCE-OPS-CHECKSUM cannot inspect bootstrap leaf"
    }
    if (-not $isLeaf) {
        throw "CGCE-OPS-CHECKSUM bootstrap module is missing"
    }
    Assert-CgceBootstrapNoReparse $leaf
    return $leaf
}

function Import-CgceVerifiedBootstrapModule(
    [string]$Path,
    [string]$Name
) {
    $expected = Get-CgceBootstrapCanonicalPath $Path
    $matching = $null
    foreach ($module in @(Get-Module -Name $Name -All)) {
        $actual = Get-CgceBootstrapCanonicalPath $module.Path
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
                (Get-CgceBootstrapCanonicalPath $_.Path).Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($loaded.Count -ne 1) {
        throw "CGCE-OPS-CHECKSUM verified module did not load exactly once"
    }
}

function Assert-CgcePrepareControlBinding($State, $Control) {
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

function Get-CgcePrepareAuthority(
    [string]$ExpectedPhase,
    [string]$OriginalPath,
    [object[]]$ExpectedOriginal,
    [string]$RunRoot,
    [string]$RunId,
    [string]$ManifestPath,
    [string]$ManifestChecksum
) {
    $state = Read-CgceRunState -RunRoot $RunRoot -RunId $RunId
    if ($state.phase -cne $ExpectedPhase -or
        $state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE prepare authority phase drift"
    }
    Assert-CgceRunMarker -State $state
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($state.server_process_paths)) `
        -Ports ([int[]]@($state.listener_ports))
    Assert-CgceNoReparseInPath -Path $state.palserver_executable
    Assert-CgceNoReparseInPath -Path $state.paths.ue4ss_dll
    if ((Get-CgceSha256 -Path $state.palserver_executable) -cne
        $state.palserver_executable_checksum) {
        throw "CGCE-OPS-CHECKSUM PalServer executable drift"
    }
    if ((Get-CgceSha256 -Path $state.paths.ue4ss_dll) -cne
        $state.ue4ss_dll_checksum) {
        throw "CGCE-OPS-CHECKSUM UE4SS DLL drift"
    }
    if ((Get-CgceSha256 -Path $state.paths.original_inventory) -cne
        $state.inventory_checksums.original) {
        throw "CGCE-OPS-CHECKSUM original inventory file drift"
    }
    $recordedOriginal = @(
        Read-CgceInventory `
            -Path $state.paths.original_inventory `
            -ExpectedKind "original"
    )
    Compare-CgceInventory `
        -Expected $ExpectedOriginal `
        -Actual $recordedOriginal
    $liveOriginal = @(Get-CgceTreeInventory -Root $OriginalPath)
    Compare-CgceInventory `
        -Expected $ExpectedOriginal `
        -Actual $liveOriginal
    $phaseOrder = @(
        "CREATED",
        "BACKUP_VERIFIED",
        "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE",
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED",
        "RESTORING",
        "RESTORED",
        "EXPORTED"
    )
    $phaseIndex = [Array]::IndexOf($phaseOrder, $state.phase)
    if ($phaseIndex -ge 1) {
        if ((Get-CgceSha256 -Path $state.paths.backup_inventory) -cne
            $state.inventory_checksums.backup) {
            throw "CGCE-OPS-CHECKSUM backup inventory file drift"
        }
        $recordedBackup = @(
            Read-CgceInventory `
                -Path $state.paths.backup_inventory `
                -ExpectedKind "backup"
        )
        Compare-CgceInventory `
            -Expected $ExpectedOriginal `
            -Actual $recordedBackup
        Compare-CgceInventory `
            -Expected $ExpectedOriginal `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
    }
    if ($phaseIndex -ge 3) {
        if ((Get-CgceSha256 -Path $state.paths.clone_inventory) -cne
            $state.inventory_checksums.clone) {
            throw "CGCE-OPS-CHECKSUM clone inventory file drift"
        }
        $recordedClone = @(
            Read-CgceInventory `
                -Path $state.paths.clone_inventory `
                -ExpectedKind "clone"
        )
        Compare-CgceInventory `
            -Expected $ExpectedOriginal `
            -Actual $recordedClone
        Compare-CgceInventory `
            -Expected $ExpectedOriginal `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.active_saved)
    }
    if ($phaseIndex -ge 4 -and
        (Get-CgceSha256 -Path $state.paths.probe_receipt) -cne
        $state.probe_receipt_checksum) {
        throw "CGCE-OPS-CHECKSUM probe receipt file drift"
    }
    if ((Get-CgceSha256 -Path $ManifestPath) -cne $ManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest drift"
    }
    Assert-CgceHandoffSource `
        -HandoffRoot $HandoffRoot `
        -ManifestPath $ManifestPath
    $control = Assert-CgceControlEvidence `
        -EvidencePath $state.paths.control_evidence `
        -ExpectedFileChecksum $state.control_evidence_checksum `
        -ExpectedBundleChecksum $state.bundle_checksum `
        -NowUtc ([DateTime]::UtcNow)
    Assert-CgcePrepareControlBinding -State $state -Control $control
    return $state
}

$lock = $null
$stateAuthorityCreated = $false
$paths = $null
$terminalPhase = $null
$terminalCode = $null
$terminalRunId = "INVALID_RUN_ID"
$exitCode = 1

try {
    if ($RunId -cmatch '^r-[0-9a-f]{32}\z') {
        $terminalRunId = $RunId
    }
    $bootstrap = Assert-CgceBootstrapTree `
        -ScriptRoot $PSScriptRoot `
        -ScriptPath $MyInvocation.MyCommand.Path `
        -BoundHandoffRoot $HandoffRoot
    $commonModule = Assert-CgceBootstrapLeaf `
        -VerifiedScriptRoot $bootstrap.script_root `
        -RelativePath "CgceDiscovery.Common.psm1"
    $contractModule = Assert-CgceBootstrapLeaf `
        -VerifiedScriptRoot $bootstrap.script_root `
        -RelativePath "modules\CgceDiscovery.Contract.psm1"
    $filesModule = Assert-CgceBootstrapLeaf `
        -VerifiedScriptRoot $bootstrap.script_root `
        -RelativePath "modules\CgceDiscovery.Files.psm1"
    $runtimeModule = Assert-CgceBootstrapLeaf `
        -VerifiedScriptRoot $bootstrap.script_root `
        -RelativePath "modules\CgceDiscovery.Runtime.psm1"
    Import-CgceVerifiedBootstrapModule `
        -Path $commonModule `
        -Name "CgceDiscovery.Common"
    Import-CgceVerifiedBootstrapModule `
        -Path $contractModule `
        -Name "CgceDiscovery.Contract"
    Import-CgceVerifiedBootstrapModule `
        -Path $filesModule `
        -Name "CgceDiscovery.Files"
    Import-CgceVerifiedBootstrapModule `
        -Path $runtimeModule `
        -Name "CgceDiscovery.Runtime"
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $terminalRunId = $RunId

    $validated = Assert-CgceControlEvidence `
        -EvidencePath $ControlEvidencePath `
        -ExpectedFileChecksum $ControlEvidenceSha256 `
        -ExpectedBundleChecksum $BundleSha256 `
        -NowUtc ([DateTime]::UtcNow)
    Assert-CgceHandoffSource `
        -HandoffRoot $HandoffRoot `
        -ManifestPath $SourceManifestPath
    $sourceManifestChecksum = Get-CgceSha256 -Path $SourceManifestPath
    if ($validated.run_id -cne $RunId) {
        throw "CGCE-OPS-ID control/run ID mismatch"
    }
    Assert-CgceEqualCanonicalPath `
        -Expected $validated.server_root `
        -Actual $ServerRoot
    Assert-CgceEqualCanonicalPath `
        -Expected $validated.ue4ss_root `
        -Actual $Ue4ssRoot
    Assert-CgceEqualCanonicalPath `
        -Expected $validated.palserver_executable `
        -Actual $ServerExecutable
    $paths = New-CgceRunPaths `
        -ServerRoot $ServerRoot `
        -SavedPath $SavedPath `
        -Ue4ssRoot $Ue4ssRoot `
        -RunRoot $RunRoot `
        -RunId $RunId
    Assert-CgceDistinctRoots -Paths @($paths.server_root, $paths.run_root)
    Assert-CgceDistinctRoots -Paths @($HandoffRoot, $paths.run_root)
    Assert-CgcePathContainedBy `
        -Path $paths.active_saved `
        -Root $paths.server_root
    Assert-CgcePathContainedBy `
        -Path $paths.ue4ss_root `
        -Root $paths.server_root
    Assert-CgceDistinctRoots -Paths @(
        $paths.active_saved,
        $paths.inactive_original,
        $paths.backup_saved,
        $paths.quarantined_clone
    )
    $probeSource = Join-Path `
        $HandoffRoot `
        "tools\windows-discovery\probe\CGCEDiscoveryInventory"

    $lock = Enter-CgceExclusiveLock `
        -ServerRoot $paths.server_root `
        -RunId $RunId
    if (Test-Path -LiteralPath $paths.run_directory) {
        throw "CGCE-OPS-STATE-EXISTS final run directory exists"
    }
    Assert-CgceNoReparseInPath -Path $ServerExecutable
    Assert-CgceNoReparseInPath -Path $paths.ue4ss_dll
    $palserverChecksum = Get-CgceSha256 -Path $ServerExecutable
    if ((Get-CgceSha256 -Path $paths.ue4ss_dll) -cne
        $validated.ue4ss_dll_sha256) {
        throw "CGCE-OPS-CHECKSUM UE4SS DLL drift"
    }
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($validated.server_process_paths)) `
        -Ports ([int[]]@($validated.listener_ports))
    Assert-CgceNoForeignRunArtifacts `
        -ServerRoot $paths.server_root `
        -Ue4ssRoot $paths.ue4ss_root `
        -RunId $RunId
    Assert-CgceNoReparseInPath -Path $paths.run_root
    Assert-CgceNoReparseInPath -Path $paths.ue4ss_root
    Assert-CgceTreeHasNoReparsePoints -Root $paths.active_saved

    Initialize-CgceRunLayout -Paths $paths
    $null = Copy-CgceFileVerified `
        -Source $ControlEvidencePath `
        -Destination $paths.control_evidence
    if ((Get-CgceSha256 -Path $paths.control_evidence) -cne
        $ControlEvidenceSha256) {
        throw "CGCE-OPS-CHECKSUM copied control evidence drift"
    }
    $original = @(Get-CgceTreeInventory -Root $paths.active_saved)
    $originalChecksum = Write-CgceInventory `
        -Entries $original `
        -Path $paths.original_inventory `
        -Kind "original"
    Assert-CgceDiscoveryDiskCapacity `
        -Entries $original `
        -BackupPath $paths.backup_saved `
        -ClonePath $paths.active_saved

    $state = New-CgceRunState `
        -RunId $RunId `
        -MaintenanceId $validated.maintenance_id `
        -Paths $paths
    $state.bundle_checksum = $BundleSha256
    $state.control_evidence_checksum = $ControlEvidenceSha256
    $state.palserver_executable = $ServerExecutable
    $state.palserver_executable_checksum = $palserverChecksum
    $state.server_process_paths = [object[]]@($validated.server_process_paths)
    $state.ue4ss_version = $validated.ue4ss_version
    $state.ue4ss_dll_checksum = $validated.ue4ss_dll_sha256
    $state.listener_ports = [object[]]@($validated.listener_ports)
    $state.inventory_checksums.original = $originalChecksum
    Write-CgceJsonAtomic -Value $state -Path $paths.genesis_state
    $null = Copy-CgceFileVerified `
        -Source $paths.genesis_state `
        -Destination $paths.state
    $stateAuthorityCreated = $true
    $genesisChecksum = Get-CgceSha256 -Path $paths.genesis_state
    Write-CgceActiveRunMarker `
        -State $state `
        -GenesisStateChecksum $genesisChecksum `
        -Path $paths.active_run_marker

    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "CREATED" `
        -OriginalPath $paths.active_saved `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    try {
        $backup = @(
            Copy-CgceTreeVerified `
                -Source $paths.active_saved `
                -Destination $paths.backup_saved
        )
        Compare-CgceInventory -Expected $original -Actual $backup
        $backupInventoryChecksum = Write-CgceInventory `
            -Entries $backup `
            -Path $paths.backup_inventory `
            -Kind "backup"
        $state = Get-CgcePrepareAuthority `
            -ExpectedPhase "CREATED" `
            -OriginalPath $paths.active_saved `
            -ExpectedOriginal $original `
            -RunRoot $paths.run_root `
            -RunId $RunId `
            -ManifestPath $SourceManifestPath `
            -ManifestChecksum $sourceManifestChecksum
        $state.inventory_checksums.backup = $backupInventoryChecksum
        $state = Set-CgceRunPhase `
            -State $state `
            -ExpectedPhase "CREATED" `
            -NextPhase "BACKUP_VERIFIED"
        Write-CgceRunState `
            -State $state `
            -StatePath $paths.state `
            -ExpectedPhase "CREATED"
    } catch {
        throw "CGCE-OPS-BACKUP backup checkpoint failed: $($_.Exception.Message)"
    }

    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "BACKUP_VERIFIED" `
        -OriginalPath $paths.active_saved `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    Move-CgceDirectoryNoOverwrite `
        -Source $paths.active_saved `
        -Destination $paths.inactive_original
    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "BACKUP_VERIFIED" `
        -OriginalPath $paths.inactive_original `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    $state = Set-CgceRunPhase `
        -State $state `
        -ExpectedPhase "BACKUP_VERIFIED" `
        -NextPhase "ORIGINAL_DEACTIVATED"
    Write-CgceRunState `
        -State $state `
        -StatePath $paths.state `
        -ExpectedPhase "BACKUP_VERIFIED"

    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "ORIGINAL_DEACTIVATED" `
        -OriginalPath $paths.inactive_original `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    try {
        $clone = @(
            Copy-CgceTreeVerified `
                -Source $paths.backup_saved `
                -Destination $paths.active_saved
        )
        Compare-CgceInventory -Expected $original -Actual $clone
        $cloneInventoryChecksum = Write-CgceInventory `
            -Entries $clone `
            -Path $paths.clone_inventory `
            -Kind "clone"
        $state = Get-CgcePrepareAuthority `
            -ExpectedPhase "ORIGINAL_DEACTIVATED" `
            -OriginalPath $paths.inactive_original `
            -ExpectedOriginal $original `
            -RunRoot $paths.run_root `
            -RunId $RunId `
            -ManifestPath $SourceManifestPath `
            -ManifestChecksum $sourceManifestChecksum
        $state.inventory_checksums.clone = $cloneInventoryChecksum
        $state = Set-CgceRunPhase `
            -State $state `
            -ExpectedPhase "ORIGINAL_DEACTIVATED" `
            -NextPhase "CLONE_ACTIVE"
        Write-CgceRunState `
            -State $state `
            -StatePath $paths.state `
            -ExpectedPhase "ORIGINAL_DEACTIVATED"
    } catch {
        throw "CGCE-OPS-CLONE clone checkpoint failed: $($_.Exception.Message)"
    }

    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "CLONE_ACTIVE" `
        -OriginalPath $paths.inactive_original `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    $probeResult = Enable-CgceInventoryProbe `
        -Ue4ssRoot $paths.ue4ss_root `
        -ProbeSource $probeSource `
        -RunDirectory $paths.run_directory `
        -RunId $RunId `
        -Paths $state.paths
    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "CLONE_ACTIVE" `
        -OriginalPath $paths.inactive_original `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum
    Assert-CgceEqualCanonicalPath `
        -Expected $state.paths.probe_receipt `
        -Actual $probeResult.path
    if ((Get-CgceSha256 -Path $state.paths.probe_receipt) -cne
        $probeResult.checksum) {
        throw "CGCE-OPS-CHECKSUM probe final receipt drift"
    }
    $state.probe_receipt_checksum = $probeResult.checksum
    $state = Set-CgceRunPhase `
        -State $state `
        -ExpectedPhase "CLONE_ACTIVE" `
        -NextPhase "PROBE_STAGED"
    Write-CgceRunState `
        -State $state `
        -StatePath $paths.state `
        -ExpectedPhase "CLONE_ACTIVE"
    $state = Get-CgcePrepareAuthority `
        -ExpectedPhase "PROBE_STAGED" `
        -OriginalPath $paths.inactive_original `
        -ExpectedOriginal $original `
        -RunRoot $paths.run_root `
        -RunId $RunId `
        -ManifestPath $SourceManifestPath `
        -ManifestChecksum $sourceManifestChecksum

    $terminalPhase = $state.phase
    $exitCode = 0
} catch {
    $terminalCode = Get-CgcePrepareErrorCode $_.Exception.Message
    Invoke-CgceSafeBlockAttempt `
        -StateAuthorityCreated $stateAuthorityCreated `
        -Paths $paths `
        -Code $terminalCode
} finally {
    if (-not (Close-CgcePrepareLock -Lock $lock)) {
        $exitCode = 1
        if ([string]::IsNullOrWhiteSpace($terminalCode)) {
            $terminalCode = "CGCE-OPS-LOCK"
        }
    }
}

if ($exitCode -eq 0) {
    Write-Output "CGCE_WINDOWS_DISCOVERY_OK $terminalPhase $terminalRunId"
} else {
    Write-Output "CGCE_WINDOWS_DISCOVERY_BLOCKED $terminalCode $terminalRunId"
}
exit $exitCode
