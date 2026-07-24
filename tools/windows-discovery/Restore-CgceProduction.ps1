#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-CgceRestoreErrorCode($ErrorRecord) {
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
    if (-not $match.Success) {
        return "CGCE-OPS-BLOCKED"
    }
    $code = $match.Groups[1].Value
    if (@(
            "CGCE-OPS-DESTINATION-EXISTS",
            "CGCE-OPS-PROBE-RECEIPT",
            "CGCE-OPS-RECOVERY-INTENT",
            "CGCE-OPS-RESTORE-RECEIPT"
        ) -ccontains $code) {
        return "CGCE-OPS-MANUAL-RECOVERY"
    }
    return $code
}

function Close-CgceRestoreLock($Lock) {
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

function Get-CgceRestoreUtcNow {
    return [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Test-CgceRestoreUtc([string]$Value) {
    if ($Value -cnotmatch
        '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') {
        return $false
    }
    try {
        $null = [DateTime]::ParseExact(
            $Value,
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal
        )
        return $true
    } catch {
        return $false
    }
}

function Get-CgceRestoreBootstrapCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "CGCE-OPS-CHECKSUM bootstrap path is required"
    }
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        throw "CGCE-OPS-CHECKSUM invalid bootstrap path"
    }
}

function Assert-CgceRestoreBootstrapNoReparse([string]$Path) {
    $current = Get-CgceRestoreBootstrapCanonicalPath $Path
    $volumeRoot = [IO.Path]::GetPathRoot($current).TrimEnd('\', '/')
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
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CGCE-OPS-CHECKSUM bootstrap reparse point is forbidden"
        }
        $parent = [IO.Path]::GetDirectoryName($current)
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

function Assert-CgceRestoreBootstrapDistinct(
    [string]$First,
    [string]$Second
) {
    $left = Get-CgceRestoreBootstrapCanonicalPath $First
    $right = Get-CgceRestoreBootstrapCanonicalPath $Second
    $leftPrefix = $left + "\"
    $rightPrefix = $right + "\"
    if ($left.Equals(
            $right,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
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

function Get-CgceRestoreBootstrapSha256(
    [string]$Path,
    [int]$MaxBytes = 0
) {
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            $algorithm = [Security.Cryptography.SHA256]::Create()
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

function Read-CgceRestoreBootstrapUtf8(
    [string]$Path,
    [int]$MaxBytes
) {
    Assert-CgceRestoreBootstrapNoReparse $Path
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
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
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        return $encoding.GetString($bytes)
    } catch {
        throw "CGCE-OPS-CHECKSUM bootstrap UTF-8 is invalid"
    }
}

function Read-CgceRestoreGenesisManifestChecksum(
    [string]$GenesisPath
) {
    $text = Read-CgceRestoreBootstrapUtf8 `
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

function Read-CgceRestoreBootstrapManifest([string]$ManifestPath) {
    $text = Read-CgceRestoreBootstrapUtf8 `
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

function Get-CgceRestoreBootstrap(
    [string]$ScriptRoot,
    [string]$ScriptPath,
    [string]$BoundRunRoot,
    [string]$BoundRunId
) {
    if ($BoundRunId -cnotmatch '^r-[0-9a-f]{32}\z') {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $actualRoot = Get-CgceRestoreBootstrapCanonicalPath $ScriptRoot
    $handoffRoot = Get-CgceRestoreBootstrapCanonicalPath (
        Join-Path $actualRoot "..\.."
    )
    $expectedRoot = Get-CgceRestoreBootstrapCanonicalPath (
        Join-Path $handoffRoot "tools\windows-discovery"
    )
    $actualScript = Get-CgceRestoreBootstrapCanonicalPath $ScriptPath
    $expectedScript = Get-CgceRestoreBootstrapCanonicalPath (
        Join-Path $expectedRoot "Restore-CgceProduction.ps1"
    )
    if (-not $actualRoot.Equals(
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $actualScript.Equals(
            $expectedScript,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM restore script is outside handoff tree"
    }
    Assert-CgceRestoreBootstrapNoReparse $handoffRoot
    Assert-CgceRestoreBootstrapNoReparse $actualScript
    Assert-CgceRestoreBootstrapDistinct $handoffRoot $BoundRunRoot

    $runRootPath = Get-CgceRestoreBootstrapCanonicalPath $BoundRunRoot
    Assert-CgceRestoreBootstrapNoReparse $runRootPath
    $genesisPath = Join-Path `
        (Join-Path $runRootPath $BoundRunId) `
        "run-state.genesis.json"
    $manifestPath = Join-Path $handoffRoot "source-manifest.sha256"
    Assert-CgceRestoreBootstrapNoReparse $manifestPath
    $expectedManifestChecksum =
        Read-CgceRestoreGenesisManifestChecksum $genesisPath
    $actualManifestChecksum = Get-CgceRestoreBootstrapSha256 `
        -Path $manifestPath `
        -MaxBytes 1048576
    if ($actualManifestChecksum -cne $expectedManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }

    $manifest = Read-CgceRestoreBootstrapManifest $manifestPath
    $trustedLeaves = [ordered]@{
        restore =
            "tools/windows-discovery/Restore-CgceProduction.ps1"
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
        $leaf = Get-CgceRestoreBootstrapCanonicalPath (
            Join-Path $handoffRoot ($relative -replace '/', '\')
        )
        Assert-CgceRestoreBootstrapNoReparse $leaf
        if ((Get-CgceRestoreBootstrapSha256 $leaf) -cne
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

function Assert-CgceRestorePreloadedModuleOrigins($Bootstrap) {
    foreach ($binding in @(
            [pscustomobject]@{
                Name = "CgceDiscovery.Contract"
                Path = $Bootstrap.contract_module
            },
            [pscustomobject]@{
                Name = "CgceDiscovery.Files"
                Path = $Bootstrap.files_module
            },
            [pscustomobject]@{
                Name = "CgceDiscovery.Runtime"
                Path = $Bootstrap.runtime_module
            },
            [pscustomobject]@{
                Name = "CgceDiscovery.Common"
                Path = $Bootstrap.common_module
            }
        )) {
        $expected = Get-CgceRestoreBootstrapCanonicalPath $binding.Path
        foreach ($module in @(Get-Module -Name $binding.Name -All)) {
            $actual = Get-CgceRestoreBootstrapCanonicalPath $module.Path
            if (-not $actual.Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "CGCE-OPS-CHECKSUM preloaded module origin drift"
            }
        }
    }
}

function Import-CgceRestoreVerifiedModule(
    [string]$Path,
    [string]$Name
) {
    $expected = Get-CgceRestoreBootstrapCanonicalPath $Path
    $matching = $null
    foreach ($module in @(Get-Module -Name $Name -All)) {
        $actual = Get-CgceRestoreBootstrapCanonicalPath $module.Path
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
                (Get-CgceRestoreBootstrapCanonicalPath $_.Path).Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($loaded.Count -ne 1) {
        throw "CGCE-OPS-CHECKSUM verified module did not load exactly once"
    }
}

function Invoke-CgceRestoreCrash([string]$Point) {
    $modules = @(Get-Module -Name "CgceDiscovery.Runtime" -All)
    if ($modules.Count -ne 1) {
        return
    }
    $null = & $modules[0] {
        param([string]$CrashPoint)
        $variable = Get-Variable `
            -Name "CgceTestRestoreCrashSeam" `
            -Scope Script `
            -ErrorAction SilentlyContinue
        if ($null -ne $variable -and $null -ne $variable.Value) {
            $null = & $variable.Value $CrashPoint
        }
    } $Point
}

function Assert-CgceRestoreExactKeys(
    $Value,
    [string[]]$Expected,
    [string]$Code
) {
    if ($null -eq $Value -or $Value -is [System.Array]) {
        throw "$Code invalid object"
    }
    $actual = @(
        $Value.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    if ([string]::Join("`n", $actual) -cne
        [string]::Join("`n", $Expected)) {
        throw "$Code object key drift"
    }
}

function Test-CgceRestoreNumericValue($Value) {
    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
    return @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    ) -contains [Type]::GetTypeCode($Value.GetType())
}

function Test-CgceRestoreJsonEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    $leftArray = $Left -is [System.Array]
    $rightArray = $Right -is [System.Array]
    if ($leftArray -or $rightArray) {
        if (-not ($leftArray -and $rightArray) -or
            @($Left).Count -ne @($Right).Count) {
            return $false
        }
        for ($index = 0; $index -lt @($Left).Count; $index += 1) {
            if (-not (Test-CgceRestoreJsonEqual `
                    @($Left)[$index] `
                    @($Right)[$index])) {
                return $false
            }
        }
        return $true
    }
    $leftNumber = Test-CgceRestoreNumericValue $Left
    $rightNumber = Test-CgceRestoreNumericValue $Right
    if ($leftNumber -or $rightNumber) {
        if (-not ($leftNumber -and $rightNumber)) {
            return $false
        }
        try {
            return [decimal]$Left -eq [decimal]$Right
        } catch {
            return $false
        }
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return $Left -is [string] -and
            $Right -is [string] -and
            $Left -ceq $Right
    }
    if ($Left -is [bool] -or $Right -is [bool]) {
        return $Left -is [bool] -and
            $Right -is [bool] -and
            $Left -eq $Right
    }
    $leftNames = @(
        $Left.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    $rightNames = @(
        $Right.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    if ($leftNames.Count -ne $rightNames.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftNames.Count; $index += 1) {
        if ($leftNames[$index] -cne $rightNames[$index] -or
            -not (Test-CgceRestoreJsonEqual `
                $Left.($leftNames[$index]) `
                $Right.($rightNames[$index]))) {
            return $false
        }
    }
    return $true
}

function Get-CgceRestoreDirectoryState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{
            artifact_type = "DIRECTORY"
            present = $false
            length = $null
            sha256 = $null
            tree_sha256 = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery directory type drift"
    }
    Assert-CgceNoReparseInPath -Path $Path
    Assert-CgceTreeHasNoReparsePoints -Root $Path
    $entries = [object[]]@(Get-CgceTreeInventory -Root $Path)
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $true
        length = $null
        sha256 = $null
        tree_sha256 = (Get-CgceInventoryTreeSha256 -Entries $entries)
    }
}

function Get-CgceRestoreStepState($Step) {
    return [pscustomobject][ordered]@{
        source = (Get-CgceRestoreDirectoryState $Step.source_path)
        destination = (
            Get-CgceRestoreDirectoryState $Step.destination_path
        )
    }
}

function Assert-CgceRestoreManualBarrier($State) {
    foreach ($errorRecord in @($State.errors)) {
        if ($errorRecord.code -ceq "CGCE-OPS-MANUAL-RECOVERY") {
            throw "CGCE-OPS-MANUAL-RECOVERY persisted manual recovery barrier"
        }
    }
}

function Assert-CgceFreshRecoveryInactivity(
    [string]$StatePath,
    [switch]$AllowCompleted
) {
    $state = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    Assert-CgceEqualCanonicalPath `
        -Expected $StatePath `
        -Actual $state.paths.state
    if ($state.source_manifest_checksum -cne
        $script:CgceRestoreBootstrap.manifest_checksum) {
        throw "CGCE-OPS-CHECKSUM state/source manifest drift"
    }
    Assert-CgceHandoffSource `
        -HandoffRoot $script:CgceRestoreBootstrap.handoff_root `
        -ManifestPath $script:CgceRestoreBootstrap.manifest_path `
        -ExpectedManifestChecksum $state.source_manifest_checksum
    Assert-CgceRestoreManualBarrier $state
    if ($AllowCompleted) {
        Assert-CgceRunMarker -State $state -AllowCompleted
    } else {
        Assert-CgceRunMarker -State $state
    }
    Assert-CgceNoServerActivity `
        -ExecutablePaths ([string[]]@($state.server_process_paths)) `
        -Ports ([int[]]@($state.listener_ports)) `
        -ReceiptRoot $state.paths.process_receipts
    return $state
}

function Read-CgceRecoveryIntentIfPresent([string]$ReceiptRoot) {
    $path = Join-Path $ReceiptRoot "000-restore-intent.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY invalid recovery intent path"
    }
    return Read-CgceJsonObject -Path $path
}

function Assert-CgceNoRestoreOperationReceipt([string]$ReceiptRoot) {
    $children = @(Get-ChildItem -LiteralPath $ReceiptRoot -Force)
    if ($children.Count -ne 1 -or
        $children[0].PSIsContainer -or
        $children[0].Name -cne "000-restore-intent.json") {
        throw "CGCE-OPS-MANUAL-RECOVERY operation receipt before RESTORING"
    }
}

function Write-CgceRecoveryIntent(
    $State,
    $Matrix,
    [string]$ReceiptRoot
) {
    if (@(Get-ChildItem -LiteralPath $ReceiptRoot -Force).Count -ne 0) {
        throw "CGCE-OPS-MANUAL-RECOVERY restore receipt root is not empty"
    }
    $statePath = $State.paths.state
    $expectedStateChecksum = Get-CgceSha256 -Path $statePath
    $fresh = Assert-CgceFreshRecoveryInactivity -StatePath $statePath
    if ((Get-CgceSha256 -Path $statePath) -cne
            $expectedStateChecksum -or
        $fresh.phase -cne $State.phase -or
        $fresh.outcome -cne $State.outcome -or
        [int64]$fresh.revision -ne [int64]$State.revision) {
        throw "CGCE-OPS-CHECKSUM recovery source state changed"
    }
    $freshMatrix = Assert-CgceRecoveryMatrix -State $fresh
    if (-not (Test-CgceRestoreJsonEqual $freshMatrix $Matrix)) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery matrix changed"
    }
    $original = [object[]]@(Read-CgceInventory `
        -Path $fresh.paths.original_inventory `
        -ExpectedKind "original")
    $originalChecksum = Get-CgceSha256 `
        -Path $fresh.paths.original_inventory
    if ($originalChecksum -cne $fresh.inventory_checksums.original) {
        throw "CGCE-OPS-CHECKSUM original inventory drift"
    }
    $intent = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_restore_intent"
        run_id = $fresh.run_id
        sequence = 0
        created_at_utc = (Get-CgceRestoreUtcNow)
        source_state_sha256 = $expectedStateChecksum
        source_phase = $fresh.phase
        source_outcome = $fresh.outcome
        source_revision = [int64]$fresh.revision
        source_updated_at_utc = $fresh.updated_at_utc
        source_errors = [object[]]@($fresh.errors)
        genesis_state_sha256 = (
            Get-CgceSha256 -Path $fresh.paths.genesis_state
        )
        original_inventory_sha256 = $originalChecksum
        original_tree_sha256 = (
            Get-CgceInventoryTreeSha256 -Entries $original
        )
        selected_case = $freshMatrix.selected_case
        paths = [pscustomobject][ordered]@{
            active_saved = $fresh.paths.active_saved
            inactive_original = $fresh.paths.inactive_original
            quarantined_clone = $fresh.paths.quarantined_clone
            original_inventory = $fresh.paths.original_inventory
            restored_inventory = $fresh.paths.restored_inventory
            restore_receipts = $fresh.paths.restore_receipts
            probe_restore_final_receipt = (
                Join-Path `
                    (Join-Path $fresh.paths.probe_receipts "restore") `
                    "999-probe-restore-final.json"
            )
        }
        steps = [object[]]@($freshMatrix.steps)
    }
    $path = Join-Path $ReceiptRoot "000-restore-intent.json"
    $guarded = Assert-CgceFreshRecoveryInactivity -StatePath $statePath
    if ((Get-CgceSha256 -Path $statePath) -cne
            $expectedStateChecksum -or
        $guarded.phase -cne $fresh.phase -or
        [int64]$guarded.revision -ne [int64]$fresh.revision) {
        throw "CGCE-OPS-CHECKSUM recovery source changed before intent"
    }
    Write-CgceJsonAtomic -Value $intent -Path $path
    $written = Read-CgceJsonObject -Path $path
    $null = Assert-CgceRecoveryMatrix -State $guarded -Intent $written
    Invoke-CgceRestoreCrash "after-000-intent"
    return $written
}

function Invoke-CgceJournaledRecoveryStep(
    [string]$StatePath,
    [string]$RecoveryIntentPath,
    [int]$Sequence
) {
    if (@(10, 20) -notcontains $Sequence) {
        throw "CGCE-OPS-MANUAL-RECOVERY unsupported recovery sequence"
    }
    $state = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    if ($state.phase -cne "RESTORING") {
        throw "CGCE-OPS-PHASE recovery step requires RESTORING"
    }
    $intent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $matrix = Assert-CgceRecoveryMatrix -State $state -Intent $intent
    $stepIndex = if ($Sequence -eq 10) { 0 } else { 1 }
    $step = @($matrix.steps)[$stepIndex]
    if ([int]$step.sequence -ne $Sequence) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery step sequence drift"
    }
    $leaf = if ($Sequence -eq 10) {
        "010-quarantine-clone.json"
    } else {
        "020-restore-original.json"
    }
    $receiptPath = Join-Path $state.paths.restore_receipts $leaf
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        return
    }

    $live = Get-CgceRestoreStepState $step
    $isBefore = Test-CgceRestoreJsonEqual $live $step.before_state
    $isAfter = Test-CgceRestoreJsonEqual $live $step.after_state
    if (-not $isBefore -and -not $isAfter) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery step layout drift"
    }
    if ($isBefore -and $step.operation -ceq "MOVE_DIRECTORY") {
        $fresh = Read-CgceRunState `
            -RunRoot $script:CgceRestoreRunRoot `
            -RunId $script:CgceRestoreRunId
        $expectedStateChecksum = Get-CgceSha256 -Path $StatePath
        $freshIntent = Read-CgceJsonObject -Path $RecoveryIntentPath
        $freshMatrix = Assert-CgceRecoveryMatrix `
            -State $fresh `
            -Intent $freshIntent
        $freshStep = @($freshMatrix.steps)[$stepIndex]
        if (-not (Test-CgceRestoreJsonEqual `
                (Get-CgceRestoreStepState $freshStep) `
                $freshStep.before_state)) {
            throw "CGCE-OPS-MANUAL-RECOVERY move preimage changed"
        }
        $guarded = Assert-CgceFreshRecoveryInactivity `
            -StatePath $StatePath
        if ($guarded.phase -cne "RESTORING" -or
            (Get-CgceSha256 -Path $StatePath) -cne
                $expectedStateChecksum) {
            throw "CGCE-OPS-CHECKSUM recovery state changed before move"
        }
        try {
            $null = Move-CgceDirectoryNoOverwrite `
                -Source $freshStep.source_path `
                -Destination $freshStep.destination_path
        } catch {
            if ($_.Exception.Message.StartsWith(
                    "CGCE-OPS-PROCESS-",
                    [StringComparison]::Ordinal
                ) -or
                $_.Exception.Message.StartsWith(
                    "CGCE-OPS-PORT-",
                    [StringComparison]::Ordinal
                ) -or
                $_.Exception.Message.StartsWith(
                    "CGCE-OPS-MANUAL-RECOVERY",
                    [StringComparison]::Ordinal
                )) {
                throw
            }
            throw "CGCE-OPS-MANUAL-RECOVERY recovery move failed"
        }
        if (-not (Test-CgceRestoreJsonEqual `
                (Get-CgceRestoreStepState $freshStep) `
                $freshStep.after_state)) {
            throw "CGCE-OPS-MANUAL-RECOVERY move postimage drift"
        }
        Invoke-CgceRestoreCrash (
            "after-{0:D3}-move-before-receipt" -f $Sequence
        )
    } elseif (-not $isAfter) {
        throw "CGCE-OPS-MANUAL-RECOVERY verification state drift"
    }

    $fresh = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    $expectedStateChecksum = Get-CgceSha256 -Path $StatePath
    $expectedIntentChecksum = Get-CgceSha256 `
        -Path $RecoveryIntentPath
    $freshIntent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $freshMatrix = Assert-CgceRecoveryMatrix `
        -State $fresh `
        -Intent $freshIntent
    $freshStep = @($freshMatrix.steps)[$stepIndex]
    if (-not (Test-CgceRestoreJsonEqual `
            (Get-CgceRestoreStepState $freshStep) `
            $freshStep.after_state)) {
        throw "CGCE-OPS-MANUAL-RECOVERY receipt postimage drift"
    }
    $previousPath = if ($Sequence -eq 10) {
        $RecoveryIntentPath
    } else {
        Join-Path $fresh.paths.restore_receipts `
            "010-quarantine-clone.json"
    }
    if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY prior recovery receipt missing"
    }
    $receipt = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_restore_operation"
        run_id = $fresh.run_id
        sequence = $Sequence
        step = $freshStep.step
        operation = $freshStep.operation
        source_path = $freshStep.source_path
        destination_path = $freshStep.destination_path
        before_state = $freshStep.before_state
        after_state = $freshStep.after_state
        previous_receipt_sha256 = (
            Get-CgceSha256 -Path $previousPath
        )
        completed_at_utc = (Get-CgceRestoreUtcNow)
    }
    $guarded = Assert-CgceFreshRecoveryInactivity `
        -StatePath $StatePath
    if ($guarded.phase -cne "RESTORING" -or
        (Get-CgceSha256 -Path $StatePath) -cne
            $expectedStateChecksum -or
        (Get-CgceSha256 -Path $RecoveryIntentPath) -cne
            $expectedIntentChecksum) {
        throw "CGCE-OPS-CHECKSUM recovery authority changed before receipt"
    }
    Write-CgceJsonAtomic -Value $receipt -Path $receiptPath
    $readIntent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $null = Assert-CgceRecoveryMatrix `
        -State $guarded `
        -Intent $readIntent
    Invoke-CgceRestoreCrash (
        "after-{0:D3}-receipt" -f $Sequence
    )
}

function Write-OrResume-CgceRestoredInventory(
    [string]$StatePath,
    [string]$RecoveryIntentPath
) {
    $state = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    if ($state.phase -cne "RESTORING") {
        throw "CGCE-OPS-PHASE restored inventory requires RESTORING"
    }
    $intent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $null = Assert-CgceRecoveryMatrix -State $state -Intent $intent
    $original = [object[]]@(Read-CgceInventory `
        -Path $state.paths.original_inventory `
        -ExpectedKind "original")
    $live = [object[]]@(Get-CgceTreeInventory `
        -Root $state.paths.active_saved)
    Compare-CgceInventory -Expected $original -Actual $live

    if (-not (Test-Path -LiteralPath $state.paths.restored_inventory)) {
        $expectedStateChecksum = Get-CgceSha256 -Path $StatePath
        $expectedIntentChecksum = Get-CgceSha256 `
            -Path $RecoveryIntentPath
        $fresh = Assert-CgceFreshRecoveryInactivity `
            -StatePath $StatePath
        if ($fresh.phase -cne "RESTORING" -or
            (Get-CgceSha256 -Path $StatePath) -cne
                $expectedStateChecksum -or
            (Get-CgceSha256 -Path $RecoveryIntentPath) -cne
                $expectedIntentChecksum) {
            throw "CGCE-OPS-CHECKSUM authority changed before inventory"
        }
        $null = Write-CgceInventory `
            -Entries $live `
            -Path $fresh.paths.restored_inventory `
            -Kind "restored"
    }
    if (-not (Test-Path `
            -LiteralPath $state.paths.restored_inventory `
            -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY restored inventory path drift"
    }
    $restored = [object[]]@(Read-CgceInventory `
        -Path $state.paths.restored_inventory `
        -ExpectedKind "restored")
    Compare-CgceInventory -Expected $original -Actual $restored
    Compare-CgceInventory `
        -Expected $restored `
        -Actual ([object[]]@(Get-CgceTreeInventory `
            -Root $state.paths.active_saved))
    $checksum = Get-CgceSha256 -Path $state.paths.restored_inventory
    Invoke-CgceRestoreCrash "after-restored-inventory"
    return $checksum
}

function Get-CgceRestoreFinalAuthority(
    $State,
    $Intent,
    [string]$RestoredInventorySha256,
    [switch]$RequireFinal
) {
    $root = $State.paths.restore_receipts
    $children = @(Get-ChildItem -LiteralPath $root -Force)
    $expectedNames = @(
        "000-restore-intent.json",
        "010-quarantine-clone.json",
        "020-restore-original.json"
    )
    if ($RequireFinal) {
        $expectedNames += "999-restore-final.json"
    }
    $actualNames = @(
        $children |
            Sort-Object -Property Name |
            ForEach-Object {
                if ($_.PSIsContainer) {
                    throw "CGCE-OPS-RESTORE-RECEIPT directory receipt child"
                }
                $_.Name
            }
    )
    if ([string]::Join("`n", $actualNames) -cne
        [string]::Join("`n", $expectedNames)) {
        throw "CGCE-OPS-RESTORE-RECEIPT recovery receipt set drift"
    }
    $matrix = Assert-CgceRecoveryMatrix -State $State -Intent $Intent
    $bindings = New-Object 'Collections.Generic.List[object]'
    foreach ($sequence in 10, 20) {
        $leaf = if ($sequence -eq 10) {
            "010-quarantine-clone.json"
        } else {
            "020-restore-original.json"
        }
        $path = Join-Path $root $leaf
        $null = $bindings.Add([pscustomobject][ordered]@{
            sequence = $sequence
            path = $path
            sha256 = (Get-CgceSha256 -Path $path)
        })
    }
    $original = [object[]]@(Read-CgceInventory `
        -Path $State.paths.original_inventory `
        -ExpectedKind "original")
    $restored = [object[]]@(Read-CgceInventory `
        -Path $State.paths.restored_inventory `
        -ExpectedKind "restored")
    $actualRestoredChecksum = Get-CgceSha256 `
        -Path $State.paths.restored_inventory
    if ($actualRestoredChecksum -cne $RestoredInventorySha256 -or
        (Get-CgceSha256 -Path $State.paths.original_inventory) -cne
            $Intent.original_inventory_sha256) {
        throw "CGCE-OPS-RESTORE-RECEIPT inventory checksum drift"
    }
    Compare-CgceInventory -Expected $original -Actual $restored
    $live = [object[]]@(Get-CgceTreeInventory `
        -Root $State.paths.active_saved)
    Compare-CgceInventory -Expected $restored -Actual $live
    $originalTree = Get-CgceInventoryTreeSha256 -Entries $original
    $restoredTree = Get-CgceInventoryTreeSha256 -Entries $restored
    $liveTree = Get-CgceInventoryTreeSha256 -Entries $live
    if ($originalTree -cne $Intent.original_tree_sha256 -or
        $restoredTree -cne $Intent.original_tree_sha256 -or
        $liveTree -cne $Intent.original_tree_sha256) {
        throw "CGCE-OPS-RESTORE-RECEIPT restored tree drift"
    }

    $probeArguments = @{
        Paths = $State.paths
        RunDirectory = $State.paths.run_directory
        RunId = $State.run_id
    }
    if ($null -ne $State.probe_receipt_checksum) {
        $probeArguments.ExpectedFinalReceiptChecksum =
            $State.probe_receipt_checksum
    }
    $null = Assert-CgceInventoryProbeRestored @probeArguments
    $probeBinding = $null
    if ($null -ne $State.probe_receipt_checksum) {
        $probePath = $Intent.paths.probe_restore_final_receipt
        if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
            throw "CGCE-OPS-PROBE-RECEIPT probe final receipt missing"
        }
        $probeBinding = [pscustomobject][ordered]@{
            path = $probePath
            sha256 = (Get-CgceSha256 -Path $probePath)
        }
    }
    return [pscustomobject]@{
        matrix = $matrix
        previous_receipt_sha256 = (
            Get-CgceSha256 -Path (
                Join-Path $root "020-restore-original.json"
            )
        )
        operation_receipts = [object[]]$bindings.ToArray()
        probe_restore_final_receipt = $probeBinding
        original_inventory = [pscustomobject][ordered]@{
            path = $State.paths.original_inventory
            sha256 = $Intent.original_inventory_sha256
            tree_sha256 = $Intent.original_tree_sha256
        }
        restored_inventory = [pscustomobject][ordered]@{
            path = $State.paths.restored_inventory
            sha256 = $actualRestoredChecksum
            tree_sha256 = $Intent.original_tree_sha256
        }
    }
}

function Assert-CgceRestoreFinalReceipt(
    $State,
    $Intent,
    $Authority,
    [string]$FinalPath
) {
    $final = Read-CgceJsonObject -Path $FinalPath
    Assert-CgceRestoreExactKeys $final @(
        "schema_version", "kind", "run_id", "sequence",
        "restore_intent_sha256", "previous_receipt_sha256",
        "operation_receipts", "probe_restore_final_receipt",
        "original_inventory", "restored_inventory", "completed_at_utc"
    ) "CGCE-OPS-RESTORE-RECEIPT"
    if ($final.schema_version -cne "1.0" -or
        $final.kind -cne "cgce_windows_discovery_restore_final" -or
        $final.run_id -cne $State.run_id -or
        [int]$final.sequence -ne 999 -or
        $final.restore_intent_sha256 -cne
            (Get-CgceSha256 -Path (
                Join-Path $State.paths.restore_receipts `
                    "000-restore-intent.json"
            )) -or
        $final.previous_receipt_sha256 -cne
            $Authority.previous_receipt_sha256 -or
        -not (Test-CgceRestoreJsonEqual `
            $final.operation_receipts `
            $Authority.operation_receipts) -or
        -not (Test-CgceRestoreJsonEqual `
            $final.probe_restore_final_receipt `
            $Authority.probe_restore_final_receipt) -or
        -not (Test-CgceRestoreJsonEqual `
            $final.original_inventory `
            $Authority.original_inventory) -or
        -not (Test-CgceRestoreJsonEqual `
            $final.restored_inventory `
            $Authority.restored_inventory) -or
        -not (Test-CgceRestoreUtc $final.completed_at_utc)) {
        throw "CGCE-OPS-RESTORE-RECEIPT final receipt authority drift"
    }
    return $final
}

function Complete-CgceRecoveryJournal(
    [string]$StatePath,
    [string]$RecoveryIntentPath,
    [string]$RestoredInventorySha256
) {
    $state = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    if ($state.phase -cne "RESTORING") {
        throw "CGCE-OPS-PHASE final journal requires RESTORING"
    }
    $intent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $finalPath = Join-Path `
        $state.paths.restore_receipts `
        "999-restore-final.json"
    if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
        $authority = Get-CgceRestoreFinalAuthority `
            -State $state `
            -Intent $intent `
            -RestoredInventorySha256 $RestoredInventorySha256 `
            -RequireFinal
        $null = Assert-CgceRestoreFinalReceipt `
            -State $state `
            -Intent $intent `
            -Authority $authority `
            -FinalPath $finalPath
        return
    }

    $authority = Get-CgceRestoreFinalAuthority `
        -State $state `
        -Intent $intent `
        -RestoredInventorySha256 $RestoredInventorySha256
    $final = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_restore_final"
        run_id = $state.run_id
        sequence = 999
        restore_intent_sha256 = (
            Get-CgceSha256 -Path $RecoveryIntentPath
        )
        previous_receipt_sha256 =
            $authority.previous_receipt_sha256
        operation_receipts = $authority.operation_receipts
        probe_restore_final_receipt =
            $authority.probe_restore_final_receipt
        original_inventory = $authority.original_inventory
        restored_inventory = $authority.restored_inventory
        completed_at_utc = (Get-CgceRestoreUtcNow)
    }
    $expectedStateChecksum = Get-CgceSha256 -Path $StatePath
    $expectedIntentChecksum = Get-CgceSha256 `
        -Path $RecoveryIntentPath
    $fresh = Assert-CgceFreshRecoveryInactivity -StatePath $StatePath
    if ($fresh.phase -cne "RESTORING" -or
        (Get-CgceSha256 -Path $StatePath) -cne
            $expectedStateChecksum -or
        (Get-CgceSha256 -Path $RecoveryIntentPath) -cne
            $expectedIntentChecksum) {
        throw "CGCE-OPS-CHECKSUM authority changed before final receipt"
    }
    Write-CgceJsonAtomic -Value $final -Path $finalPath
    $freshIntent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $readAuthority = Get-CgceRestoreFinalAuthority `
        -State $fresh `
        -Intent $freshIntent `
        -RestoredInventorySha256 $RestoredInventorySha256 `
        -RequireFinal
    $null = Assert-CgceRestoreFinalReceipt `
        -State $fresh `
        -Intent $freshIntent `
        -Authority $readAuthority `
        -FinalPath $finalPath
    Invoke-CgceRestoreCrash "after-999"
}

function Get-CgceRestoringValidationState($RestoredState, $Intent) {
    $state = Read-CgceJsonObject -Path $RestoredState.paths.state
    $state.phase = "RESTORING"
    $state.revision = [int64]$RestoredState.revision - 1
    $state.inventory_checksums.restored = $null
    if ([int64]$state.revision -lt
        ([int64]$Intent.source_revision + 1)) {
        throw "CGCE-OPS-RESTORE-RECEIPT restored revision drift"
    }
    return $state
}

function Assert-CgceRestoredCompletionAuthority(
    [string]$StatePath,
    [string]$RecoveryIntentPath
) {
    $state = Read-CgceRunState `
        -RunRoot $script:CgceRestoreRunRoot `
        -RunId $script:CgceRestoreRunId
    Assert-CgceEqualCanonicalPath `
        -Expected $StatePath `
        -Actual $state.paths.state
    if ($state.phase -cne "RESTORED") {
        throw "CGCE-OPS-PHASE completed authority requires RESTORED"
    }
    Assert-CgceRestoreManualBarrier $state
    Assert-CgceRunMarker -State $state -AllowCompleted
    $intent = Read-CgceJsonObject -Path $RecoveryIntentPath
    $restoring = Get-CgceRestoringValidationState `
        -RestoredState $state `
        -Intent $intent
    $null = Assert-CgceRecoveryMatrix `
        -State $restoring `
        -Intent $intent
    $restoredChecksum = Get-CgceSha256 `
        -Path $state.paths.restored_inventory
    if ($state.inventory_checksums.restored -cne $restoredChecksum) {
        throw "CGCE-OPS-RESTORE-RECEIPT restored state binding drift"
    }
    $authority = Get-CgceRestoreFinalAuthority `
        -State $restoring `
        -Intent $intent `
        -RestoredInventorySha256 $restoredChecksum `
        -RequireFinal
    $null = Assert-CgceRestoreFinalReceipt `
        -State $restoring `
        -Intent $intent `
        -Authority $authority `
        -FinalPath (
            Join-Path $state.paths.restore_receipts `
                "999-restore-final.json"
        )
    Assert-CgceHandoffSource `
        -HandoffRoot $script:CgceRestoreBootstrap.handoff_root `
        -ManifestPath $script:CgceRestoreBootstrap.manifest_path `
        -ExpectedManifestChecksum $state.source_manifest_checksum
    return $state
}

function Complete-CgceRunMarker(
    [string]$StatePath,
    [string]$RecoveryIntentPath
) {
    $state = Assert-CgceRestoredCompletionAuthority `
        -StatePath $StatePath `
        -RecoveryIntentPath $RecoveryIntentPath
    $activeExists = Test-Path `
        -LiteralPath $state.paths.active_run_marker `
        -PathType Leaf
    $completedExists = Test-Path `
        -LiteralPath $state.paths.completed_run_marker `
        -PathType Leaf
    if (($activeExists -and $completedExists) -or
        (-not $activeExists -and -not $completedExists)) {
        throw "CGCE-OPS-CONTROL exact run marker location required"
    }

    $expectedStateChecksum = Get-CgceSha256 -Path $StatePath
    $probeArguments = @{
        Paths = $state.paths
        RunDirectory = $state.paths.run_directory
        RunId = $state.run_id
    }
    if ($null -ne $state.probe_receipt_checksum) {
        $probeArguments.ExpectedFinalReceiptChecksum =
            $state.probe_receipt_checksum
    }
    $null = Assert-CgceInventoryProbeRestored @probeArguments
    $fresh = Assert-CgceFreshRecoveryInactivity `
        -StatePath $StatePath `
        -AllowCompleted
    if ($fresh.phase -cne "RESTORED" -or
        (Get-CgceSha256 -Path $StatePath) -cne
            $expectedStateChecksum) {
        throw "CGCE-OPS-CHECKSUM state changed before marker completion"
    }

    $activeExists = Test-Path `
        -LiteralPath $fresh.paths.active_run_marker `
        -PathType Leaf
    $completedExists = Test-Path `
        -LiteralPath $fresh.paths.completed_run_marker `
        -PathType Leaf
    if ($activeExists -and -not $completedExists) {
        try {
            [IO.File]::Move(
                $fresh.paths.active_run_marker,
                $fresh.paths.completed_run_marker
            )
        } catch {
            throw "CGCE-OPS-CONTROL completed marker move failed"
        }
    } elseif (-not $activeExists -and $completedExists) {
        # Exact completed-only replay is a validated no-op.
    } else {
        throw "CGCE-OPS-CONTROL exact run marker location required"
    }
    Invoke-CgceRestoreCrash "after-completed-marker-before-terminal"
}

$lock = $null
$modulesReady = $false
$lockHeld = $false
$statePath = $null
$recoveryIntentPath = $null
$terminalPhase = $null
$terminalCode = $null
$terminalRunId = "INVALID_RUN_ID"
$exitCode = 1
$script:CgceRestoreRunRoot = $null
$script:CgceRestoreRunId = $null
$script:CgceRestoreBootstrap = $null

try {
    if ($RunId -cmatch '^r-[0-9a-f]{32}\z') {
        $terminalRunId = $RunId
    }
    $bootstrap = Get-CgceRestoreBootstrap `
        -ScriptRoot $PSScriptRoot `
        -ScriptPath $MyInvocation.MyCommand.Path `
        -BoundRunRoot $RunRoot `
        -BoundRunId $RunId
    Assert-CgceRestorePreloadedModuleOrigins -Bootstrap $bootstrap
    Import-CgceRestoreVerifiedModule `
        -Path $bootstrap.contract_module `
        -Name "CgceDiscovery.Contract"
    Import-CgceRestoreVerifiedModule `
        -Path $bootstrap.files_module `
        -Name "CgceDiscovery.Files"
    Import-CgceRestoreVerifiedModule `
        -Path $bootstrap.runtime_module `
        -Name "CgceDiscovery.Runtime"
    Import-CgceRestoreVerifiedModule `
        -Path $bootstrap.common_module `
        -Name "CgceDiscovery.Common"
    Assert-CgceRestorePreloadedModuleOrigins -Bootstrap $bootstrap
    $modulesReady = $true

    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $terminalRunId = $RunId
    $script:CgceRestoreRunRoot = $RunRoot
    $script:CgceRestoreRunId = $RunId
    $script:CgceRestoreBootstrap = $bootstrap
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
    Assert-CgceDistinctRoots -Paths @(
        $bootstrap.handoff_root,
        $state.paths.run_root
    )
    $statePath = $state.paths.state
    $recoveryIntentPath = Join-Path `
        $state.paths.restore_receipts `
        "000-restore-intent.json"

    if ($state.phase -ceq "RESTORED") {
        $null = Complete-CgceRunMarker `
            -StatePath $statePath `
            -RecoveryIntentPath $recoveryIntentPath
    } else {
        Assert-CgceRunMarker -State $state
        Assert-CgceRestoreManualBarrier $state
        $null = Assert-CgceFreshRecoveryInactivity `
            -StatePath $statePath
        $original = [object[]]@(Read-CgceInventory `
            -Path $state.paths.original_inventory `
            -ExpectedKind "original")
        if ((Get-CgceSha256 -Path $state.paths.original_inventory) -cne
            $state.inventory_checksums.original) {
            throw "CGCE-OPS-CHECKSUM original inventory drift"
        }

        $intent = Read-CgceRecoveryIntentIfPresent `
            -ReceiptRoot $state.paths.restore_receipts
        if ($null -eq $intent) {
            if ($state.phase -ceq "RESTORING") {
                throw "CGCE-OPS-MANUAL-RECOVERY RESTORING without intent"
            }
            $matrix = Assert-CgceRecoveryMatrix -State $state
            $intent = Write-CgceRecoveryIntent `
                -State $state `
                -Matrix $matrix `
                -ReceiptRoot $state.paths.restore_receipts
            $null = Write-CgceRecoveryRunState `
                -StatePath $statePath `
                -RecoveryIntentPath $recoveryIntentPath
            Invoke-CgceRestoreCrash "after-RESTORING-CAS-before-010"
            $state = Read-CgceRunState `
                -RunRoot $RunRoot `
                -RunId $RunId
            $matrix = Assert-CgceRecoveryMatrix `
                -State $state `
                -Intent $intent
        } else {
            $matrix = Assert-CgceRecoveryMatrix `
                -State $state `
                -Intent $intent
            if ($state.phase -cne "RESTORING") {
                if ($state.phase -cne $intent.source_phase) {
                    throw "CGCE-OPS-MANUAL-RECOVERY intent/source phase mismatch"
                }
                Assert-CgceNoRestoreOperationReceipt `
                    -ReceiptRoot $state.paths.restore_receipts
                $null = Write-CgceRecoveryRunState `
                    -StatePath $statePath `
                    -RecoveryIntentPath $recoveryIntentPath
                Invoke-CgceRestoreCrash `
                    "after-RESTORING-CAS-before-010"
                $state = Read-CgceRunState `
                    -RunRoot $RunRoot `
                    -RunId $RunId
                $matrix = Assert-CgceRecoveryMatrix `
                    -State $state `
                    -Intent $intent
            }
        }

        foreach ($step in @($matrix.steps)) {
            $null = Invoke-CgceJournaledRecoveryStep `
                -StatePath $statePath `
                -RecoveryIntentPath $recoveryIntentPath `
                -Sequence ([int]$step.sequence)
        }
        $state = Read-CgceRunState `
            -RunRoot $RunRoot `
            -RunId $RunId
        $original = [object[]]@(Read-CgceInventory `
            -Path $state.paths.original_inventory `
            -ExpectedKind "original")
        Compare-CgceInventory `
            -Expected $original `
            -Actual ([object[]]@(Get-CgceTreeInventory `
                -Root $state.paths.active_saved))

        $probeRestore = @{
            Paths = $state.paths
            RunDirectory = $state.paths.run_directory
            RunId = $RunId
        }
        if ($null -ne $state.probe_receipt_checksum) {
            $probeRestore.ExpectedFinalReceiptChecksum =
                $state.probe_receipt_checksum
        }
        $null = Assert-CgceFreshRecoveryInactivity `
            -StatePath $statePath
        $null = Restore-CgceInventoryProbe @probeRestore

        $state = Read-CgceRunState `
            -RunRoot $RunRoot `
            -RunId $RunId
        Compare-CgceInventory `
            -Expected $original `
            -Actual ([object[]]@(Get-CgceTreeInventory `
                -Root $state.paths.active_saved))
        $restoredInventorySha = Write-OrResume-CgceRestoredInventory `
            -StatePath $statePath `
            -RecoveryIntentPath $recoveryIntentPath
        $null = Complete-CgceRecoveryJournal `
            -StatePath $statePath `
            -RecoveryIntentPath $recoveryIntentPath `
            -RestoredInventorySha256 $restoredInventorySha
        $null = Complete-CgceRecoveryRunState `
            -StatePath $statePath `
            -RecoveryIntentPath $recoveryIntentPath
        Invoke-CgceRestoreCrash "after-RESTORED-state-before-marker"
        $null = Complete-CgceRunMarker `
            -StatePath $statePath `
            -RecoveryIntentPath $recoveryIntentPath
    }
    $terminalPhase = "RESTORED"
    $exitCode = 0
} catch {
    $terminalCode = Get-CgceRestoreErrorCode -ErrorRecord $_
    if ($modulesReady -and $lockHeld -and
        $null -ne $statePath -and
        $null -ne $recoveryIntentPath) {
        try {
            $null = Block-CgceRecoveryRunState `
                -StatePath $statePath `
                -RecoveryIntentPath $recoveryIntentPath `
                -Code $terminalCode
        } catch {
            # Preserve the original failure. The fixed-purpose blocker either
            # proves its exact authority and commits or performs no write.
        }
    }
    $exitCode = 1
} finally {
    if (-not (Close-CgceRestoreLock -Lock $lock)) {
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
