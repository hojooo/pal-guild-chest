#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [switch]$Resume
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-CgceExportErrorCode($ErrorRecord) {
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
            "CGCE-OPS-OUTPUT-EXISTS"
        ) -ccontains $code) {
        return "CGCE-OPS-EXPORT-EXISTS"
    }
    return $code
}

function Close-CgceExportLock($Lock) {
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

function Get-CgceExportBootstrapCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "CGCE-OPS-CHECKSUM bootstrap path is required"
    }
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        throw "CGCE-OPS-CHECKSUM invalid bootstrap path"
    }
}

function Assert-CgceExportBootstrapNoReparse([string]$Path) {
    $current = Get-CgceExportBootstrapCanonicalPath $Path
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

function Assert-CgceExportBootstrapDistinct(
    [string]$First,
    [string]$Second
) {
    $left = Get-CgceExportBootstrapCanonicalPath $First
    $right = Get-CgceExportBootstrapCanonicalPath $Second
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

function Get-CgceExportBootstrapSha256(
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

function Read-CgceExportBootstrapUtf8(
    [string]$Path,
    [int]$MaxBytes
) {
    Assert-CgceExportBootstrapNoReparse $Path
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

function Read-CgceExportGenesisManifestChecksum(
    [string]$GenesisPath
) {
    $text = Read-CgceExportBootstrapUtf8 `
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

function Read-CgceExportBootstrapManifest([string]$ManifestPath) {
    $text = Read-CgceExportBootstrapUtf8 `
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

function Get-CgceExportBootstrap(
    [string]$ScriptRoot,
    [string]$ScriptPath,
    [string]$BoundRunRoot,
    [string]$BoundRunId
) {
    if ($BoundRunId -cnotmatch '^r-[0-9a-f]{32}\z') {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $actualRoot = Get-CgceExportBootstrapCanonicalPath $ScriptRoot
    $handoffRoot = Get-CgceExportBootstrapCanonicalPath (
        Join-Path $actualRoot "..\.."
    )
    $expectedRoot = Get-CgceExportBootstrapCanonicalPath (
        Join-Path $handoffRoot "tools\windows-discovery"
    )
    $actualScript = Get-CgceExportBootstrapCanonicalPath $ScriptPath
    $expectedScript = Get-CgceExportBootstrapCanonicalPath (
        Join-Path $expectedRoot "Export-CgceDiscoveryEvidence.ps1"
    )
    if (-not $actualRoot.Equals(
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $actualScript.Equals(
            $expectedScript,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CHECKSUM export script is outside handoff tree"
    }
    Assert-CgceExportBootstrapNoReparse $handoffRoot
    Assert-CgceExportBootstrapNoReparse $actualScript
    Assert-CgceExportBootstrapDistinct $handoffRoot $BoundRunRoot

    $runRootPath = Get-CgceExportBootstrapCanonicalPath $BoundRunRoot
    Assert-CgceExportBootstrapNoReparse $runRootPath
    $genesisPath = Join-Path `
        (Join-Path $runRootPath $BoundRunId) `
        "run-state.genesis.json"
    $manifestPath = Join-Path $handoffRoot "source-manifest.sha256"
    Assert-CgceExportBootstrapNoReparse $manifestPath
    $expectedManifestChecksum =
        Read-CgceExportGenesisManifestChecksum $genesisPath
    $actualManifestChecksum = Get-CgceExportBootstrapSha256 `
        -Path $manifestPath `
        -MaxBytes 1048576
    if ($actualManifestChecksum -cne $expectedManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }

    $manifest = Read-CgceExportBootstrapManifest $manifestPath
    $trustedLeaves = [ordered]@{
        export =
            "tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1"
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
        $leaf = Get-CgceExportBootstrapCanonicalPath (
            Join-Path $handoffRoot ($relative -replace '/', '\')
        )
        Assert-CgceExportBootstrapNoReparse $leaf
        if ((Get-CgceExportBootstrapSha256 $leaf) -cne
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

function Assert-CgceExportPreloadedModuleOrigins($Bootstrap) {
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
        $expected = Get-CgceExportBootstrapCanonicalPath $binding.Path
        foreach ($module in @(Get-Module -Name $binding.Name -All)) {
            $actual = Get-CgceExportBootstrapCanonicalPath $module.Path
            if (-not $actual.Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "CGCE-OPS-CHECKSUM preloaded module origin drift"
            }
        }
    }
}

function Import-CgceExportVerifiedModule(
    [string]$Path,
    [string]$Name
) {
    $expected = Get-CgceExportBootstrapCanonicalPath $Path
    $matching = $null
    foreach ($module in @(Get-Module -Name $Name -All)) {
        $actual = Get-CgceExportBootstrapCanonicalPath $module.Path
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
                (Get-CgceExportBootstrapCanonicalPath $_.Path).Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($loaded.Count -ne 1) {
        throw "CGCE-OPS-CHECKSUM verified module did not load exactly once"
    }
}

function Assert-CgceExportExactKeys(
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
    if ($actual.Count -ne $Expected.Count) {
        throw "$Code object key count drift"
    }
    for ($index = 0; $index -lt $Expected.Count; $index += 1) {
        if ($actual[$index] -cne $Expected[$index]) {
            throw "$Code object key order drift"
        }
    }
}

function Test-CgceExportUtc([string]$Value) {
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

function Test-CgceExportChecksum($Value) {
    return $Value -is [string] -and
        $Value -cmatch '^[0-9a-f]{64}\z'
}

function Assert-CgceExportRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith("/") -or
        $Path.Contains("\") -or
        $Path.Contains(":") -or
        $Path -cmatch '[\x00-\x1f]' -or
        $Path -cnotmatch '^[A-Za-z0-9._/-]+\z') {
        throw "CGCE-OPS-EXPORT-ALLOWLIST invalid relative path"
    }
    foreach ($component in $Path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -ceq "." -or $component -ceq "..") {
            throw "CGCE-OPS-EXPORT-ALLOWLIST invalid path component"
        }
    }
}

function Assert-CgceExportPathNotSensitive([string]$Path) {
    Assert-CgceExportRelativePath $Path
    foreach ($component in $Path.Split('/')) {
        if ($component.Equals(
                "Saved",
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $component.Equals(
                "Config",
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $component.Equals(
                "mods.txt",
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "CGCE-OPS-EXPORT-SENSITIVE sensitive path is forbidden"
        }
    }
    $extension = [IO.Path]::GetExtension($Path)
    if (@(".sav", ".ini", ".key", ".pem") -icontains $extension) {
        throw "CGCE-OPS-EXPORT-SENSITIVE sensitive extension is forbidden"
    }
}

function Assert-CgceExportNoSensitiveJsonKeys($Value) {
    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Array]) {
        foreach ($entry in @($Value)) {
            Assert-CgceExportNoSensitiveJsonKeys $entry
        }
        return
    }
    if ($Value -is [string] -or
        $Value -is [ValueType]) {
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $normalized = (
            [string]$property.Name -replace '[^A-Za-z0-9]', ''
        ).ToLowerInvariant()
        if ($normalized.EndsWith(
                "password",
                [StringComparison]::Ordinal
            ) -or
            $normalized.EndsWith(
                "apikey",
                [StringComparison]::Ordinal
            ) -or
            $normalized.EndsWith(
                "privatekey",
                [StringComparison]::Ordinal
            )) {
            throw "CGCE-OPS-EXPORT-SENSITIVE sensitive JSON field is forbidden"
        }
        Assert-CgceExportNoSensitiveJsonKeys $property.Value
    }
}

function Test-CgceExportPayloadPathAllowed([string]$Path) {
    if (@(
            "control-evidence.json",
            "run-state.json",
            "inventories/original.json",
            "inventories/backup.json",
            "inventories/clone.json",
            "inventories/restored.json",
            "capture/UE4SS_ObjectDump.txt"
        ) -ccontains $Path) {
        return $true
    }
    return $Path -cmatch
        '^capture/CXXHeaderDump/[A-Za-z0-9._/-]+\z'
}

function Assert-CgceExportControlBinding($State, $Control) {
    if ($Control.run_id -cne $State.run_id -or
        $Control.maintenance_id -cne $State.maintenance_id -or
        $Control.bundle_checksum -cne $State.bundle_checksum -or
        $Control.ue4ss_version -cne $State.ue4ss_version -or
        $Control.ue4ss_dll_sha256 -cne
            $State.ue4ss_dll_checksum -or
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

function Assert-CgceExportFixedSourcePaths($State) {
    $runDirectory = $State.paths.run_directory
    $expected = [ordered]@{
        control_evidence = Join-Path $runDirectory "control-evidence.json"
        state = Join-Path $runDirectory "run-state.json"
        original_inventory = Join-Path `
            $runDirectory `
            "inventories\original.json"
        backup_inventory = Join-Path `
            $runDirectory `
            "inventories\backup.json"
        clone_inventory = Join-Path `
            $runDirectory `
            "inventories\clone.json"
        restored_inventory = Join-Path `
            $runDirectory `
            "inventories\restored.json"
        capture = Join-Path $runDirectory "capture"
        capture_inventory = Join-Path `
            $runDirectory `
            "capture-inventory.json"
    }
    foreach ($name in $expected.Keys) {
        try {
            Assert-CgceEqualCanonicalPath `
                -Expected $expected[$name] `
                -Actual $State.paths.$name
        } catch {
            throw "CGCE-OPS-EXPORT-ALLOWLIST source path authority drift"
        }
    }
}

function New-CgceExportExpectedPayload(
    $State,
    [string]$StateChecksum,
    [object[]]$CaptureInventory
) {
    $expected =
        [System.Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    $bindings = @(
        [pscustomobject]@{
            Source = $State.paths.control_evidence
            Relative = "control-evidence.json"
            Checksum = $State.control_evidence_checksum
        },
        [pscustomobject]@{
            Source = $State.paths.state
            Relative = "run-state.json"
            Checksum = $StateChecksum
        },
        [pscustomobject]@{
            Source = $State.paths.original_inventory
            Relative = "inventories/original.json"
            Checksum = $State.inventory_checksums.original
        },
        [pscustomobject]@{
            Source = $State.paths.backup_inventory
            Relative = "inventories/backup.json"
            Checksum = $State.inventory_checksums.backup
        },
        [pscustomobject]@{
            Source = $State.paths.clone_inventory
            Relative = "inventories/clone.json"
            Checksum = $State.inventory_checksums.clone
        },
        [pscustomobject]@{
            Source = $State.paths.restored_inventory
            Relative = "inventories/restored.json"
            Checksum = $State.inventory_checksums.restored
        }
    )
    foreach ($binding in $bindings) {
        if (-not (Test-Path `
                -LiteralPath $binding.Source `
                -PathType Leaf) -or
            (Get-CgceSha256 $binding.Source) -cne
                $binding.Checksum) {
            throw "CGCE-OPS-CHECKSUM export payload source drift"
        }
        $item = Get-Item -LiteralPath $binding.Source -Force
        $expected.Add(
            $binding.Relative,
            [pscustomobject][ordered]@{
                relative_path = $binding.Relative
                length = [int64]$item.Length
                sha256 = $binding.Checksum
            }
        )
    }
    $headerCount = 0
    foreach ($entry in @($CaptureInventory)) {
        $relative = "capture/" + $entry.relative_path
        Assert-CgceExportPathNotSensitive $relative
        if (-not (Test-CgceExportPayloadPathAllowed $relative) -or
            $expected.ContainsKey($relative)) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST invalid capture payload"
        }
        if ($relative.StartsWith(
                "capture/CXXHeaderDump/",
                [StringComparison]::Ordinal
            )) {
            $headerCount += 1
        }
        $expected.Add(
            $relative,
            [pscustomobject][ordered]@{
                relative_path = $relative
                length = [int64]$entry.length
                sha256 = $entry.sha256
            }
        )
    }
    if ($headerCount -lt 1 -or $expected.Count -lt 8) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST export payload is incomplete"
    }
    return ,$expected
}

function Assert-CgceExportPayloadMatchesExpected(
    [object[]]$Records,
    $Expected
) {
    if ($null -eq $Expected -or
        @($Records).Count -ne $Expected.Count) {
        throw "CGCE-OPS-CHECKSUM export payload authority drift"
    }
    foreach ($record in @($Records)) {
        if ($null -eq $record -or
            $record.relative_path -isnot [string] -or
            -not $Expected.ContainsKey($record.relative_path)) {
            throw "CGCE-OPS-CHECKSUM export payload authority drift"
        }
        $bound = $Expected[$record.relative_path]
        try {
            $length = [int64]$record.length
        } catch {
            throw "CGCE-OPS-CHECKSUM export payload authority drift"
        }
        if ($length -ne [int64]$bound.length -or
            $record.sha256 -cne $bound.sha256) {
            throw "CGCE-OPS-CHECKSUM export payload authority drift"
        }
    }
}

function Assert-CgceExportSourceAuthority(
    $State,
    $Bootstrap
) {
    if ($State.phase -cne "RESTORED" -or
        $State.outcome -cne "ACTIVE" -or
        @($State.errors).Count -ne 0) {
        throw "CGCE-OPS-EXPORT-PHASE exact RESTORED active state required"
    }
    Assert-CgceRunMarker -State $state -AllowCompleted
    if (Test-Path `
            -LiteralPath $State.paths.active_run_marker `
            -PathType Leaf) {
        throw "CGCE-OPS-EXPORT-PHASE active run marker is forbidden"
    }
    if (-not (Test-Path `
            -LiteralPath $State.paths.completed_run_marker `
            -PathType Leaf)) {
        throw "CGCE-OPS-EXPORT-PHASE completed run marker is required"
    }
    if ($State.source_manifest_checksum -cne
        $Bootstrap.manifest_checksum) {
        throw "CGCE-OPS-CHECKSUM state/source manifest drift"
    }
    Assert-CgceHandoffSource `
        -HandoffRoot $Bootstrap.handoff_root `
        -ManifestPath $Bootstrap.manifest_path `
        -ExpectedManifestChecksum $State.source_manifest_checksum
    Assert-CgceExportFixedSourcePaths $State
    foreach ($path in @(
            $State.paths.control_evidence,
            $State.paths.state,
            $State.paths.original_inventory,
            $State.paths.backup_inventory,
            $State.paths.clone_inventory,
            $State.paths.restored_inventory,
            $State.paths.capture,
            $State.paths.capture_inventory
        )) {
        try {
            Assert-CgceNoReparseInPath -Path $path
        } catch {
            throw "CGCE-OPS-EXPORT-ALLOWLIST source reparse is forbidden"
        }
    }

    if ((Get-CgceSha256 $State.paths.control_evidence) -cne
        $State.control_evidence_checksum) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST control evidence drift"
    }
    try {
        $control = Read-CgceJsonObject $State.paths.control_evidence
        Assert-CgceExportNoSensitiveJsonKeys $control
        $control = Assert-CgceControlEvidence `
            -EvidencePath $State.paths.control_evidence `
            -ExpectedFileChecksum $State.control_evidence_checksum `
            -ExpectedBundleChecksum $State.bundle_checksum `
            -NowUtc ([DateTime]::UtcNow)
        Assert-CgceExportControlBinding `
            -State $State `
            -Control $control
    } catch {
        if ($_.Exception.Message.StartsWith(
                "CGCE-OPS-EXPORT-SENSITIVE",
                [StringComparison]::Ordinal
            ) -or
            $_.Exception.Message.StartsWith(
                "CGCE-OPS-CONTROL-EXPIRED",
                [StringComparison]::Ordinal
            )) {
            throw
        }
        throw "CGCE-OPS-EXPORT-ALLOWLIST invalid control evidence"
    }

    $inventoryBindings = @(
        [pscustomobject]@{
            Name = "original"
            Path = $State.paths.original_inventory
            Checksum = $State.inventory_checksums.original
        },
        [pscustomobject]@{
            Name = "backup"
            Path = $State.paths.backup_inventory
            Checksum = $State.inventory_checksums.backup
        },
        [pscustomobject]@{
            Name = "clone"
            Path = $State.paths.clone_inventory
            Checksum = $State.inventory_checksums.clone
        },
        [pscustomobject]@{
            Name = "restored"
            Path = $State.paths.restored_inventory
            Checksum = $State.inventory_checksums.restored
        }
    )
    foreach ($binding in $inventoryBindings) {
        if (-not (Test-CgceExportChecksum $binding.Checksum) -or
            -not (Test-Path `
                -LiteralPath $binding.Path `
                -PathType Leaf) -or
            (Get-CgceSha256 $binding.Path) -cne $binding.Checksum) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST inventory authority drift"
        }
        try {
            $null = @(
                Read-CgceInventory `
                    -Path $binding.Path `
                    -ExpectedKind $binding.Name
            )
            Assert-CgceExportNoSensitiveJsonKeys (
                Read-CgceJsonObject $binding.Path
            )
        } catch {
            if ($_.Exception.Message.StartsWith(
                    "CGCE-OPS-EXPORT-SENSITIVE",
                    [StringComparison]::Ordinal
                )) {
                throw
            }
            throw "CGCE-OPS-EXPORT-ALLOWLIST invalid inventory document"
        }
    }

    if (-not (Test-CgceExportChecksum `
            $State.capture_inventory_checksum) -or
        -not (Test-Path `
            -LiteralPath $State.paths.capture_inventory `
            -PathType Leaf) -or
        (Get-CgceSha256 $State.paths.capture_inventory) -cne
            $State.capture_inventory_checksum) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST capture inventory drift"
    }
    $captureChildren = @(
        Get-ChildItem -LiteralPath $State.paths.capture -Force
    )
    if ($captureChildren.Count -ne 2 -or
        -not (Test-Path `
            -LiteralPath (Join-Path `
                $State.paths.capture `
                "UE4SS_ObjectDump.txt") `
            -PathType Leaf) -or
        -not (Test-Path `
            -LiteralPath (Join-Path `
                $State.paths.capture `
                "CXXHeaderDump") `
            -PathType Container)) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST exact capture shape required"
    }
    $liveCapture = @(Get-CgceTreeInventory `
        -Root $State.paths.capture)
    foreach ($entry in $liveCapture) {
        Assert-CgceExportPathNotSensitive (
            "capture/" + $entry.relative_path
        )
        if (-not (Test-CgceExportPayloadPathAllowed (
                "capture/" + $entry.relative_path
            ))) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST unallowlisted capture path"
        }
    }
    try {
        $recordedCapture = @(Read-CgceInventory `
            -Path $State.paths.capture_inventory `
            -ExpectedKind "capture")
        Compare-CgceInventory `
            -Expected $recordedCapture `
            -Actual $liveCapture
    } catch {
        throw "CGCE-OPS-EXPORT-ALLOWLIST capture inventory mismatch"
    }
    $stateChecksum = Get-CgceSha256 $State.paths.state
    $expectedPayload = New-CgceExportExpectedPayload `
        -State $State `
        -StateChecksum $stateChecksum `
        -CaptureInventory $liveCapture
    return [pscustomobject]@{
        state_checksum = $stateChecksum
        expected_payload = $expectedPayload
    }
}

function New-CgceExportStaging(
    $State,
    [string]$StagingRoot,
    $ExpectedPayload
) {
    if (Test-Path -LiteralPath $StagingRoot) {
        throw "CGCE-OPS-EXPORT-EXISTS export staging path exists"
    }
    New-Item -ItemType Directory -Path $StagingRoot | Out-Null
    foreach ($relative in @(
            "inventories",
            "capture",
            "capture\CXXHeaderDump"
        )) {
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $StagingRoot $relative) | Out-Null
    }

    $fileBindings = @(
        [pscustomobject]@{
            Source = $State.paths.control_evidence
            Relative = "control-evidence.json"
        },
        [pscustomobject]@{
            Source = $State.paths.state
            Relative = "run-state.json"
        },
        [pscustomobject]@{
            Source = $State.paths.original_inventory
            Relative = "inventories\original.json"
        },
        [pscustomobject]@{
            Source = $State.paths.backup_inventory
            Relative = "inventories\backup.json"
        },
        [pscustomobject]@{
            Source = $State.paths.clone_inventory
            Relative = "inventories\clone.json"
        },
        [pscustomobject]@{
            Source = $State.paths.restored_inventory
            Relative = "inventories\restored.json"
        },
        [pscustomobject]@{
            Source = Join-Path `
                $State.paths.capture `
                "UE4SS_ObjectDump.txt"
            Relative = "capture\UE4SS_ObjectDump.txt"
        }
    )
    foreach ($binding in $fileBindings) {
        try {
            $null = Copy-CgceFileVerified `
                -Source $binding.Source `
                -Destination (Join-Path `
                    $StagingRoot `
                    $binding.Relative)
        } catch {
            throw "CGCE-OPS-EXPORT-ALLOWLIST export staging copy failed"
        }
    }
    try {
        $null = @(Copy-CgceTreeVerified `
            -Source (Join-Path $State.paths.capture "CXXHeaderDump") `
            -Destination (Join-Path `
                $StagingRoot `
                "capture\CXXHeaderDump"))
    } catch {
        throw "CGCE-OPS-EXPORT-ALLOWLIST header staging copy failed"
    }

    $stagedInventory = @(Get-CgceTreeInventory -Root $StagingRoot)
    Assert-CgceExportPayloadMatchesExpected `
        -Records $stagedInventory `
        -Expected $ExpectedPayload
    $payload = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $stagedInventory) {
        Assert-CgceExportPathNotSensitive $entry.relative_path
        if (-not (Test-CgceExportPayloadPathAllowed `
                $entry.relative_path)) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST staging entry is not allowed"
        }
        $null = $payload.Add([pscustomobject][ordered]@{
            relative_path = $entry.relative_path
            length = [int64]$entry.length
            sha256 = $entry.sha256
        })
    }
    if ($payload.Count -lt 8) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST export payload is incomplete"
    }
    $manifest = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_export_manifest"
        run_id = $State.run_id
        privacy = "PRIVATE"
        created_at_utc = [DateTime]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        payload = [object[]]$payload.ToArray()
    }
    Write-CgceJsonAtomic `
        -Value $manifest `
        -Path (Join-Path $StagingRoot "export-manifest.json")
    return $manifest
}

function New-CgceExportZip(
    [string]$StagingRoot,
    [string]$ArchivePath
) {
    $tempPath = "$ArchivePath.tmp"
    if ((Test-Path -LiteralPath $ArchivePath) -or
        (Test-Path -LiteralPath $tempPath)) {
        throw "CGCE-OPS-EXPORT-EXISTS export archive path exists"
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = $null
    $archive = $null
    try {
        $fileStream = [IO.File]::Open(
            $tempPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        $files = @(
            Get-ChildItem `
                -LiteralPath $StagingRoot `
                -File `
                -Force `
                -Recurse |
                Sort-Object {
                    $_.FullName.Substring(
                        $StagingRoot.Length + 1
                    ).Replace("\", "/")
                }
        )
        foreach ($file in $files) {
            $relative = $file.FullName.Substring(
                $StagingRoot.Length + 1
            ).Replace("\", "/")
            Assert-CgceExportPathNotSensitive $relative
            $entry = $archive.CreateEntry(
                $relative,
                [IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = [DateTimeOffset]::new(
                1980, 1, 1, 0, 0, 0,
                [TimeSpan]::Zero
            )
            $source = [IO.File]::OpenRead($file.FullName)
            try {
                $destination = $entry.Open()
                try {
                    $source.CopyTo($destination)
                } finally {
                    $destination.Dispose()
                }
            } finally {
                $source.Dispose()
            }
        }
    } catch {
        if ($_.Exception.Message.StartsWith(
                "CGCE-OPS-",
                [StringComparison]::Ordinal
            )) {
            throw
        }
        throw "CGCE-OPS-CHECKSUM export archive creation failed"
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
    if (Test-Path -LiteralPath $ArchivePath) {
        throw "CGCE-OPS-EXPORT-EXISTS export archive path exists"
    }
    [IO.File]::Move($tempPath, $ArchivePath)
}

function Write-CgceExportSidecar(
    [string]$ArchivePath,
    [string]$SidecarPath
) {
    $tempPath = "$SidecarPath.tmp"
    if ((Test-Path -LiteralPath $SidecarPath) -or
        (Test-Path -LiteralPath $tempPath)) {
        throw "CGCE-OPS-EXPORT-EXISTS export sidecar path exists"
    }
    $text = (Get-CgceSha256 $ArchivePath) + "  " +
        (Split-Path -Leaf $ArchivePath) + "`n"
    [IO.File]::WriteAllText(
        $tempPath,
        $text,
        (New-Object Text.UTF8Encoding($false))
    )
    if (Test-Path -LiteralPath $SidecarPath) {
        throw "CGCE-OPS-EXPORT-EXISTS export sidecar path exists"
    }
    [IO.File]::Move($tempPath, $SidecarPath)
}

function Get-CgceExportEntryBytes(
    $Entry,
    [int64]$MaxBytes
) {
    if ([int64]$Entry.Length -lt 0 -or
        [int64]$Entry.Length -gt $MaxBytes) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST archive entry size is invalid"
    }
    $stream = $Entry.Open()
    try {
        $bytes = New-Object byte[] ([int]$Entry.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read(
                $bytes,
                $offset,
                $bytes.Length - $offset
            )
            if ($read -le 0) {
                throw "CGCE-OPS-CHECKSUM archive entry truncated"
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) {
            throw "CGCE-OPS-CHECKSUM archive entry length drift"
        }
        return ,$bytes
    } finally {
        $stream.Dispose()
    }
}

function Get-CgceExportBytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function ConvertFrom-CgceExportUtf8([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST UTF-8 BOM is forbidden"
    }
    try {
        return (New-Object Text.UTF8Encoding(
            $false,
            $true
        )).GetString($Bytes)
    } catch {
        throw "CGCE-OPS-EXPORT-ALLOWLIST invalid UTF-8"
    }
}

function Assert-CgceExportManifest(
    $Manifest,
    [string]$RunId,
    $ExpectedPayload
) {
    Assert-CgceExportExactKeys `
        $Manifest `
        @(
            "schema_version",
            "kind",
            "run_id",
            "privacy",
            "created_at_utc",
            "payload"
        ) `
        "CGCE-OPS-EXPORT-ALLOWLIST"
    if ($Manifest.schema_version -cne "1.0" -or
        $Manifest.kind -cne
            "cgce_windows_discovery_export_manifest" -or
        $Manifest.run_id -cne $RunId -or
        $Manifest.privacy -cne "PRIVATE" -or
        -not (Test-CgceExportUtc $Manifest.created_at_utc) -or
        $Manifest.payload -isnot [System.Array] -or
        @($Manifest.payload).Count -lt 8) {
        throw "CGCE-OPS-EXPORT-ALLOWLIST invalid export manifest"
    }
    $previous = $null
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::Ordinal
    )
    foreach ($entry in @($Manifest.payload)) {
        Assert-CgceExportExactKeys `
            $entry `
            @("relative_path", "length", "sha256") `
            "CGCE-OPS-EXPORT-ALLOWLIST"
        Assert-CgceExportPathNotSensitive $entry.relative_path
        if (-not (Test-CgceExportPayloadPathAllowed `
                $entry.relative_path) -or
            -not $seen.Add([string]$entry.relative_path) -or
            ($null -ne $previous -and
                [string]::CompareOrdinal(
                    $previous,
                    [string]$entry.relative_path
                ) -ge 0) -or
            $entry.length -isnot [ValueType] -or
            $entry.length -is [bool] -or
            [decimal]::Truncate([decimal]$entry.length) -ne
                [decimal]$entry.length -or
            [decimal]$entry.length -lt 0 -or
            -not (Test-CgceExportChecksum $entry.sha256)) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST invalid manifest payload"
        }
        $previous = $entry.relative_path
    }
    Assert-CgceExportPayloadMatchesExpected `
        -Records ([object[]]@($Manifest.payload)) `
        -Expected $ExpectedPayload
}

function Assert-CgceExportArchive(
    [string]$ArchivePath,
    [string]$SidecarPath,
    [string]$RunId,
    [string]$ExpectedRestoredStateChecksum,
    $ExpectedPayload
) {
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        throw "CGCE-OPS-EXPORT-EXISTS export archive and sidecar are required"
    }
    $sidecarText = [IO.File]::ReadAllText($SidecarPath)
    $expectedSidecar = (Get-CgceSha256 $ArchivePath) + "  " +
        (Split-Path -Leaf $ArchivePath) + "`n"
    if ($sidecarText -cne $expectedSidecar) {
        throw "CGCE-OPS-CHECKSUM export sidecar mismatch"
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    } catch {
        throw "CGCE-OPS-CHECKSUM export archive is unreadable"
    }
    try {
        $entries = @($archive.Entries)
        $names = New-Object 'System.Collections.Generic.HashSet[string]' (
            [StringComparer]::Ordinal
        )
        $byName = @{}
        foreach ($entry in $entries) {
            Assert-CgceExportPathNotSensitive $entry.FullName
            if ($entry.FullName.EndsWith(
                    "/",
                    [StringComparison]::Ordinal
                ) -or
                -not $names.Add($entry.FullName)) {
                throw "CGCE-OPS-EXPORT-ALLOWLIST invalid archive entry"
            }
            $byName[$entry.FullName] = $entry
        }
        if (-not $byName.ContainsKey("export-manifest.json")) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST export manifest is missing"
        }
        $manifestBytes = Get-CgceExportEntryBytes `
            -Entry $byName["export-manifest.json"] `
            -MaxBytes 1048576
        try {
            $manifest = (ConvertFrom-CgceExportUtf8 `
                $manifestBytes) | ConvertFrom-Json
        } catch {
            if ($_.Exception.Message.StartsWith(
                    "CGCE-OPS-",
                    [StringComparison]::Ordinal
                )) {
                throw
            }
            throw "CGCE-OPS-EXPORT-ALLOWLIST invalid export manifest JSON"
        }
        Assert-CgceExportManifest `
            -Manifest $manifest `
            -RunId $RunId `
            -ExpectedPayload $ExpectedPayload
        if ($entries.Count -ne (@($manifest.payload).Count + 1)) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST archive entry count drift"
        }
        foreach ($record in @($manifest.payload)) {
            if (-not $byName.ContainsKey($record.relative_path)) {
                throw "CGCE-OPS-EXPORT-ALLOWLIST manifest payload missing"
            }
            $entry = $byName[$record.relative_path]
            $bytes = Get-CgceExportEntryBytes `
                -Entry $entry `
                -MaxBytes 1073741824
            if ([int64]$bytes.Length -ne [int64]$record.length -or
                (Get-CgceExportBytesSha256 $bytes) -cne
                    $record.sha256) {
                throw "CGCE-OPS-CHECKSUM archive payload checksum mismatch"
            }
        }
        if ($byName.ContainsKey("export-manifest.json") -and
            @($manifest.payload | Where-Object {
                $_.relative_path -ceq "export-manifest.json"
            }).Count -ne 0) {
            throw "CGCE-OPS-EXPORT-ALLOWLIST manifest cannot list itself"
        }
        $stateRecord = @($manifest.payload | Where-Object {
            $_.relative_path -ceq "run-state.json"
        })
        if ($stateRecord.Count -ne 1 -or
            $stateRecord[0].sha256 -cne
                $ExpectedRestoredStateChecksum) {
            throw "CGCE-OPS-CHECKSUM archived RESTORED state mismatch"
        }
    } finally {
        $archive.Dispose()
    }
}

function Complete-CgceExportState(
    [string]$BoundRunRoot,
    [string]$BoundRunId,
    [string]$ExpectedRestoredStateChecksum
) {
    $state = Read-CgceRunState `
        -RunRoot $BoundRunRoot `
        -RunId $BoundRunId
    if ($state.phase -cne "RESTORED" -or
        $state.outcome -cne "ACTIVE" -or
        (Get-CgceSha256 $state.paths.state) -cne
            $ExpectedRestoredStateChecksum) {
        throw "CGCE-OPS-CHECKSUM RESTORED state changed before export commit"
    }
    Assert-CgceRunMarker -State $state -AllowCompleted
    $state = Set-CgceRunPhase `
        -State $state `
        -ExpectedPhase "RESTORED" `
        -NextPhase "EXPORTED"
    $state.outcome = "SUCCEEDED"
    Write-CgceRunState `
        -State $state `
        -StatePath $state.paths.state `
        -ExpectedPhase "RESTORED"
    $state = Read-CgceRunState `
        -RunRoot $BoundRunRoot `
        -RunId $BoundRunId
    if ($state.phase -cne "EXPORTED" -or
        $state.outcome -cne "SUCCEEDED") {
        throw "CGCE-OPS-CHECKSUM EXPORTED state read-back mismatch"
    }
    Assert-CgceRunMarker -State $state -AllowCompleted
}

$lock = $null
$terminalCode = $null
$terminalRunId = "INVALID_RUN_ID"
$exitCode = 1

try {
    if ($RunId -cmatch '^r-[0-9a-f]{32}\z') {
        $terminalRunId = $RunId
    }
    $bootstrap = Get-CgceExportBootstrap `
        -ScriptRoot $PSScriptRoot `
        -ScriptPath $MyInvocation.MyCommand.Path `
        -BoundRunRoot $RunRoot `
        -BoundRunId $RunId
    Assert-CgceExportPreloadedModuleOrigins -Bootstrap $bootstrap
    Import-CgceExportVerifiedModule `
        -Path $bootstrap.contract_module `
        -Name "CgceDiscovery.Contract"
    Import-CgceExportVerifiedModule `
        -Path $bootstrap.files_module `
        -Name "CgceDiscovery.Files"
    Import-CgceExportVerifiedModule `
        -Path $bootstrap.runtime_module `
        -Name "CgceDiscovery.Runtime"
    Import-CgceExportVerifiedModule `
        -Path $bootstrap.common_module `
        -Name "CgceDiscovery.Common"
    Assert-CgceExportPreloadedModuleOrigins -Bootstrap $bootstrap

    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $terminalRunId = $RunId
    Assert-CgceHandoffSource `
        -HandoffRoot $bootstrap.handoff_root `
        -ManifestPath $bootstrap.manifest_path `
        -ExpectedManifestChecksum $bootstrap.manifest_checksum
    $provisional = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    $lockRoot = $provisional.paths.server_root
    $lock = Enter-CgceExclusiveLock `
        -ServerRoot $lockRoot `
        -RunId $RunId

    $state = Read-CgceRunState `
        -RunRoot $RunRoot `
        -RunId $RunId
    Assert-CgceEqualCanonicalPath `
        -Expected $lockRoot `
        -Actual $state.paths.server_root
    Assert-CgceDistinctRoots -Paths @(
        $bootstrap.handoff_root,
        $state.paths.run_root
    )
    $outputRoot = Resolve-CgceCanonicalPath `
        -Path $OutputDirectory `
        -MustExist $true
    Assert-CgceNoReparseInPath -Path $outputRoot
    Assert-CgceDistinctRoots -Paths @(
        $bootstrap.handoff_root,
        $outputRoot,
        $state.paths.run_root,
        $state.paths.server_root
    )
    $authority = Assert-CgceExportSourceAuthority `
        -State $state `
        -Bootstrap $bootstrap

    $archiveName = "CGCE-Windows-Discovery-$RunId.zip"
    $archivePath = Join-Path $outputRoot $archiveName
    $sidecarPath = "$archivePath.sha256"
    $stagingRoot = Join-Path `
        $outputRoot `
        ".$archiveName.staging"
    if ($Resume) {
        if (Test-Path -LiteralPath $stagingRoot) {
            throw "CGCE-OPS-EXPORT-EXISTS stale export staging path exists"
        }
        Assert-CgceExportArchive `
            -ArchivePath $archivePath `
            -SidecarPath $sidecarPath `
            -RunId $RunId `
            -ExpectedRestoredStateChecksum $authority.state_checksum `
            -ExpectedPayload $authority.expected_payload
    } else {
        if ((Test-Path -LiteralPath $archivePath) -or
            (Test-Path -LiteralPath $sidecarPath) -or
            (Test-Path -LiteralPath $stagingRoot) -or
            (Test-Path -LiteralPath "$archivePath.tmp") -or
            (Test-Path -LiteralPath "$sidecarPath.tmp")) {
            throw "CGCE-OPS-EXPORT-EXISTS export output already exists"
        }
        $null = New-CgceExportStaging `
            -State $state `
            -StagingRoot $stagingRoot `
            -ExpectedPayload $authority.expected_payload
        if ((Get-CgceSha256 `
                (Join-Path $stagingRoot "run-state.json")) -cne
            $authority.state_checksum) {
            throw "CGCE-OPS-CHECKSUM staged RESTORED state drift"
        }
        New-CgceExportZip `
            -StagingRoot $stagingRoot `
            -ArchivePath $archivePath
        Write-CgceExportSidecar `
            -ArchivePath $archivePath `
            -SidecarPath $sidecarPath
        Assert-CgceExportArchive `
            -ArchivePath $archivePath `
            -SidecarPath $sidecarPath `
            -RunId $RunId `
            -ExpectedRestoredStateChecksum $authority.state_checksum `
            -ExpectedPayload $authority.expected_payload
        [IO.Directory]::Delete($stagingRoot, $true)
    }
    Assert-CgceExportArchive `
        -ArchivePath $archivePath `
        -SidecarPath $sidecarPath `
        -RunId $RunId `
        -ExpectedRestoredStateChecksum $authority.state_checksum `
        -ExpectedPayload $authority.expected_payload
    Complete-CgceExportState `
        -BoundRunRoot $RunRoot `
        -BoundRunId $RunId `
        -ExpectedRestoredStateChecksum $authority.state_checksum
    $exitCode = 0
} catch {
    $terminalCode = Get-CgceExportErrorCode $_
    $exitCode = 1
} finally {
    if (-not (Close-CgceExportLock -Lock $lock)) {
        $exitCode = 1
        if ([string]::IsNullOrWhiteSpace($terminalCode)) {
            $terminalCode = "CGCE-OPS-LOCK"
        }
    }
}

if ($exitCode -eq 0) {
    Write-Output "CGCE_WINDOWS_DISCOVERY_OK EXPORTED $terminalRunId"
} else {
    if ([string]::IsNullOrWhiteSpace($terminalCode)) {
        $terminalCode = "CGCE-OPS-BLOCKED"
    }
    Write-Output "CGCE_WINDOWS_DISCOVERY_BLOCKED $terminalCode $terminalRunId"
}
exit $exitCode
