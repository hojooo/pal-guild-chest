Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:MaxJsonBytes = 1048576
$script:MaxJsonDepth = 64
$script:CgceTestStatePersistenceSeam = $null
$script:CgceFileReplaceMethod = $null

$script:CgceNextPhase = @{
    CREATED = "BACKUP_VERIFIED"
    BACKUP_VERIFIED = "ORIGINAL_DEACTIVATED"
    ORIGINAL_DEACTIVATED = "CLONE_ACTIVE"
    CLONE_ACTIVE = "PROBE_STAGED"
    PROBE_STAGED = "RUNNING"
    RUNNING = "CAPTURED"
    RESTORED = "EXPORTED"
}

$script:CgcePhases = @(
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

$script:CgceStateKeys = @(
    "schema_version",
    "kind",
    "revision",
    "run_id",
    "maintenance_id",
    "phase",
    "outcome",
    "created_at_utc",
    "updated_at_utc",
    "bundle_checksum",
    "control_evidence_checksum",
    "source_manifest_checksum",
    "palserver_executable",
    "palserver_executable_checksum",
    "ue4ss_version",
    "server_process_paths",
    "ue4ss_dll_checksum",
    "listener_ports",
    "paths",
    "inventory_checksums",
    "probe_receipt_checksum",
    "process_launch_receipt_checksum",
    "process_result_receipt_checksum",
    "capture_inventory_checksum",
    "errors"
)

$script:CgcePathKeys = @(
    "server_root",
    "run_root",
    "run_directory",
    "state",
    "genesis_state",
    "control_evidence",
    "active_run_marker",
    "completed_run_marker",
    "active_saved",
    "inactive_original",
    "quarantined_clone",
    "backup_saved",
    "original_inventory",
    "backup_inventory",
    "clone_inventory",
    "restored_inventory",
    "ue4ss_root",
    "ue4ss_dll",
    "mods_txt",
    "mods_original",
    "mods_test",
    "probe_staged",
    "probe_quarantine",
    "object_dump",
    "object_dump_original",
    "object_dump_quarantine",
    "cxx_header_dump",
    "cxx_header_dump_original",
    "cxx_header_dump_quarantine",
    "ue4ss_log",
    "ue4ss_log_original",
    "ue4ss_log_quarantine",
    "capture",
    "probe_intent",
    "probe_receipt",
    "probe_receipts",
    "process_launch_receipt",
    "process_result_receipt",
    "process_receipts",
    "capture_inventory",
    "restore_receipts"
)

$script:CgceControlKeys = @(
    "schema_version",
    "kind",
    "maintenance_id",
    "run_id",
    "operator",
    "server_root",
    "palserver_executable",
    "server_process_paths",
    "server_process_paths_complete",
    "ue4ss_root",
    "ue4ss_version",
    "ue4ss_dll_sha256",
    "listener_ports",
    "production_restart_disabled",
    "external_access_blocked",
    "players_disconnected",
    "bundle_checksum",
    "verified_at_utc",
    "valid_until_utc"
)

$script:CgceHandoffPaths = @(
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
[Array]::Sort($script:CgceHandoffPaths, [StringComparer]::Ordinal)

function Test-CgceRunId([string]$Value) {
    return $Value -cmatch '^r-[0-9a-f]{32}\z'
}

function Test-CgceMaintenanceId([string]$Value) {
    return $Value -cmatch '^m-[0-9a-f]{32}\z'
}

function Test-CgceChecksum($Value) {
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}\z'
}

function Get-CgceSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CGCE-OPS-CHECKSUM missing file"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Skip-CgceJsonWhitespace($Parser) {
    while ($Parser.Position -lt $Parser.Length) {
        $character = $Parser.Text[$Parser.Position]
        if ($character -eq ' ' -or $character -eq "`t" -or
            $character -eq "`r" -or $character -eq "`n") {
            $Parser.Position += 1
        } else {
            break
        }
    }
}

function Read-CgceJsonStringToken($Parser) {
    if ($Parser.Position -ge $Parser.Length -or $Parser.Text[$Parser.Position] -ne '"') {
        throw "CGCE-OPS-JSON expected string"
    }
    $Parser.Position += 1
    $builder = New-Object System.Text.StringBuilder
    :jsonString while ($Parser.Position -lt $Parser.Length) {
        $character = $Parser.Text[$Parser.Position]
        $Parser.Position += 1
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ([int]$character -lt 0x20) {
            throw "CGCE-OPS-JSON unescaped control character"
        }
        if ($character -eq '\') {
            if ($Parser.Position -ge $Parser.Length) {
                throw "CGCE-OPS-JSON incomplete escape"
            }
            $escape = $Parser.Text[$Parser.Position]
            $Parser.Position += 1
            switch -CaseSensitive ($escape) {
                '"' { $null = $builder.Append('"'); continue jsonString }
                '\' { $null = $builder.Append('\'); continue jsonString }
                '/' { $null = $builder.Append('/'); continue jsonString }
                'b' { $null = $builder.Append([char]0x08); continue jsonString }
                'f' { $null = $builder.Append([char]0x0c); continue jsonString }
                'n' { $null = $builder.Append([char]0x0a); continue jsonString }
                'r' { $null = $builder.Append([char]0x0d); continue jsonString }
                't' { $null = $builder.Append([char]0x09); continue jsonString }
                'u' {
                    if ($Parser.Position + 4 -gt $Parser.Length) {
                        throw "CGCE-OPS-JSON incomplete unicode escape"
                    }
                    $hex = $Parser.Text.Substring($Parser.Position, 4)
                    if ($hex -cnotmatch '^[0-9A-Fa-f]{4}\z') {
                        throw "CGCE-OPS-JSON invalid unicode escape"
                    }
                    $Parser.Position += 4
                    $codeUnit = [Convert]::ToInt32($hex, 16)
                    if ($codeUnit -ge 0xd800 -and $codeUnit -le 0xdbff) {
                        if ($Parser.Position + 6 -gt $Parser.Length -or
                            $Parser.Text.Substring($Parser.Position, 2) -cne '\u') {
                            throw "CGCE-OPS-JSON unpaired high surrogate"
                        }
                        $lowHex = $Parser.Text.Substring($Parser.Position + 2, 4)
                        if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}\z') {
                            throw "CGCE-OPS-JSON invalid low surrogate"
                        }
                        $low = [Convert]::ToInt32($lowHex, 16)
                        if ($low -lt 0xdc00 -or $low -gt 0xdfff) {
                            throw "CGCE-OPS-JSON invalid low surrogate"
                        }
                        $Parser.Position += 6
                        $codePoint = 0x10000 + (($codeUnit - 0xd800) * 0x400) + ($low - 0xdc00)
                        $null = $builder.Append([char]::ConvertFromUtf32($codePoint))
                    } elseif ($codeUnit -ge 0xdc00 -and $codeUnit -le 0xdfff) {
                        throw "CGCE-OPS-JSON unpaired low surrogate"
                    } else {
                        $null = $builder.Append([char]$codeUnit)
                    }
                    continue jsonString
                }
                default { throw "CGCE-OPS-JSON invalid escape" }
            }
        }
        $code = [int]$character
        if ($code -ge 0xd800 -and $code -le 0xdbff) {
            if ($Parser.Position -ge $Parser.Length) {
                throw "CGCE-OPS-JSON unpaired high surrogate"
            }
            $lowCharacter = $Parser.Text[$Parser.Position]
            $lowCode = [int]$lowCharacter
            if ($lowCode -lt 0xdc00 -or $lowCode -gt 0xdfff) {
                throw "CGCE-OPS-JSON unpaired high surrogate"
            }
            $Parser.Position += 1
            $null = $builder.Append($character)
            $null = $builder.Append($lowCharacter)
        } elseif ($code -ge 0xdc00 -and $code -le 0xdfff) {
            throw "CGCE-OPS-JSON unpaired low surrogate"
        } else {
            $null = $builder.Append($character)
        }
    }
    throw "CGCE-OPS-JSON unterminated string"
}

function Read-CgceJsonNumberToken($Parser) {
    $remaining = $Parser.Text.Substring($Parser.Position)
    $match = [regex]::Match(
        $remaining,
        '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        throw "CGCE-OPS-JSON invalid number"
    }
    $token = $match.Value
    $Parser.Position += $token.Length
    try {
        return [decimal]::Parse(
            $token,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "CGCE-OPS-JSON number is outside supported range"
    }
}

function Read-CgceJsonArray($Parser, [int]$Depth) {
    if ($Depth -ge $script:MaxJsonDepth) {
        throw "CGCE-OPS-JSON maximum depth exceeded"
    }
    $Parser.Position += 1
    $values = New-Object System.Collections.Generic.List[object]
    Skip-CgceJsonWhitespace $Parser
    if ($Parser.Position -lt $Parser.Length -and $Parser.Text[$Parser.Position] -eq ']') {
        $Parser.Position += 1
        return ,$values.ToArray()
    }
    while ($true) {
        $value = Read-CgceJsonValue $Parser ($Depth + 1)
        $null = $values.Add($value)
        Skip-CgceJsonWhitespace $Parser
        if ($Parser.Position -ge $Parser.Length) {
            throw "CGCE-OPS-JSON unterminated array"
        }
        $separator = $Parser.Text[$Parser.Position]
        $Parser.Position += 1
        if ($separator -eq ']') {
            return ,$values.ToArray()
        }
        if ($separator -ne ',') {
            throw "CGCE-OPS-JSON expected array separator"
        }
        Skip-CgceJsonWhitespace $Parser
    }
}

function Read-CgceJsonObjectValue($Parser, [int]$Depth) {
    if ($Depth -ge $script:MaxJsonDepth) {
        throw "CGCE-OPS-JSON maximum depth exceeded"
    }
    $Parser.Position += 1
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $value = New-Object PSObject
    Skip-CgceJsonWhitespace $Parser
    if ($Parser.Position -lt $Parser.Length -and $Parser.Text[$Parser.Position] -eq '}') {
        $Parser.Position += 1
        return $value
    }
    while ($true) {
        $key = Read-CgceJsonStringToken $Parser
        if (-not $keys.Add($key)) {
            throw "CGCE-OPS-JSON duplicate object key"
        }
        Skip-CgceJsonWhitespace $Parser
        if ($Parser.Position -ge $Parser.Length -or $Parser.Text[$Parser.Position] -ne ':') {
            throw "CGCE-OPS-JSON expected object colon"
        }
        $Parser.Position += 1
        Skip-CgceJsonWhitespace $Parser
        $propertyValue = Read-CgceJsonValue $Parser ($Depth + 1)
        try {
            $property = [System.Management.Automation.PSNoteProperty]::new($key, $propertyValue)
            $value.PSObject.Properties.Add($property)
        } catch {
            throw "CGCE-OPS-JSON object key cannot be represented"
        }
        Skip-CgceJsonWhitespace $Parser
        if ($Parser.Position -ge $Parser.Length) {
            throw "CGCE-OPS-JSON unterminated object"
        }
        $separator = $Parser.Text[$Parser.Position]
        $Parser.Position += 1
        if ($separator -eq '}') {
            return $value
        }
        if ($separator -ne ',') {
            throw "CGCE-OPS-JSON expected object separator"
        }
        Skip-CgceJsonWhitespace $Parser
    }
}

function Read-CgceJsonValue($Parser, [int]$Depth) {
    Skip-CgceJsonWhitespace $Parser
    if ($Parser.Position -ge $Parser.Length) {
        throw "CGCE-OPS-JSON expected value"
    }
    $character = $Parser.Text[$Parser.Position]
    switch -CaseSensitive ($character) {
        '{' { return Read-CgceJsonObjectValue $Parser $Depth }
        '[' { return ,(Read-CgceJsonArray $Parser $Depth) }
        '"' { return Read-CgceJsonStringToken $Parser }
        't' {
            if ($Parser.Position + 4 -le $Parser.Length -and
                $Parser.Text.Substring($Parser.Position, 4) -ceq "true") {
                $Parser.Position += 4
                return $true
            }
            throw "CGCE-OPS-JSON invalid literal"
        }
        'f' {
            if ($Parser.Position + 5 -le $Parser.Length -and
                $Parser.Text.Substring($Parser.Position, 5) -ceq "false") {
                $Parser.Position += 5
                return $false
            }
            throw "CGCE-OPS-JSON invalid literal"
        }
        'n' {
            if ($Parser.Position + 4 -le $Parser.Length -and
                $Parser.Text.Substring($Parser.Position, 4) -ceq "null") {
                $Parser.Position += 4
                return $null
            }
            throw "CGCE-OPS-JSON invalid literal"
        }
        default {
            if ($character -eq '-' -or ($character -ge '0' -and $character -le '9')) {
                return Read-CgceJsonNumberToken $Parser
            }
            throw "CGCE-OPS-JSON invalid value"
        }
    }
}

function Read-CgceStrictJsonDocument([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CGCE-OPS-JSON missing file"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt $script:MaxJsonBytes) {
        throw "CGCE-OPS-JSON maximum size exceeded"
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw "CGCE-OPS-JSON UTF-8 BOM is not allowed"
    }
    try {
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString($bytes)
    } catch {
        throw "CGCE-OPS-JSON invalid UTF-8"
    }
    $parser = [pscustomobject]@{
        Text = $text
        Position = 0
        Length = $text.Length
    }
    Skip-CgceJsonWhitespace $parser
    if ($parser.Position -ge $parser.Length) {
        throw "CGCE-OPS-JSON empty input"
    }
    $rootCharacter = $parser.Text[$parser.Position]
    $rootKind = switch -CaseSensitive ($rootCharacter) {
        '{' { "Object" }
        '[' { "Array" }
        '"' { "String" }
        't' { "Boolean" }
        'f' { "Boolean" }
        'n' { "Null" }
        default { "Number" }
    }
    $value = Read-CgceJsonValue $parser 0
    Skip-CgceJsonWhitespace $parser
    if ($parser.Position -ne $parser.Length) {
        throw "CGCE-OPS-JSON trailing input"
    }
    return [pscustomobject]@{
        RootKind = $rootKind
        Value = $value
    }
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
    foreach ($value in @($parsed.Value)) {
        if ($value -isnot [string]) {
            throw "CGCE-OPS-JSON array values must be strings"
        }
    }
    return ,([string[]]@($parsed.Value))
}

function Assert-CgceExactKeys($Value, [string[]]$Expected, [string]$Code) {
    if ($null -eq $Value) {
        throw "$Code object is required"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Expected.Count) {
        throw "$Code exact key set required"
    }
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
    foreach ($name in $Expected) {
        $null = $expectedSet.Add($name)
    }
    foreach ($name in $actual) {
        if (-not $expectedSet.Contains($name)) {
            throw "$Code unknown or missing field"
        }
    }
}

function Assert-CgceStrictUtc([string]$Value, [string]$Code) {
    if ($Value -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') {
        throw "$Code timestamp must be strict UTC"
    }
    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )
    if (-not $ok) {
        throw "$Code timestamp must be strict UTC"
    }
    return $parsed
}

function Assert-CgceDenseArray($Value, [string]$Code) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Array]) {
        throw "$Code dense array required"
    }
}

function Assert-CgceUniqueStrings($Value, [bool]$AllowEmpty, [string]$Code) {
    Assert-CgceDenseArray $Value $Code
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
            throw "$Code non-empty string array required"
        }
        if (-not $seen.Add($item)) {
            throw "$Code duplicate array value"
        }
    }
    if (-not $AllowEmpty -and @($Value).Count -eq 0) {
        throw "$Code non-empty array required"
    }
}

function Assert-CgceWindowsPathContained([string]$Path, [string]$Root, [string]$Code) {
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    } catch {
        throw "$Code invalid Windows path"
    }
    if ($fullPath -ine $fullRoot -and
        -not $fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Code path escapes server root"
    }
}

function Assert-CgceControlEvidence(
    [string]$EvidencePath,
    [string]$ExpectedFileChecksum,
    [string]$ExpectedBundleChecksum,
    [DateTime]$NowUtc
) {
    if (-not (Test-CgceChecksum $ExpectedFileChecksum) -or
        -not (Test-CgceChecksum $ExpectedBundleChecksum)) {
        throw "CGCE-OPS-CHECKSUM expected lowercase SHA-256"
    }
    $actualChecksum = Get-CgceSha256 -Path $EvidencePath
    if ($actualChecksum -cne $ExpectedFileChecksum) {
        throw "CGCE-OPS-CHECKSUM control evidence file drift"
    }
    $evidence = Read-CgceJsonObject -Path $EvidencePath
    Assert-CgceExactKeys $evidence $script:CgceControlKeys "CGCE-OPS-CONTROL"
    if ($evidence.schema_version -cne "1.0" -or
        $evidence.kind -cne "cgce_windows_discovery_control") {
        throw "CGCE-OPS-CONTROL unsupported schema"
    }
    if (-not (Test-CgceMaintenanceId $evidence.maintenance_id) -or
        -not (Test-CgceRunId $evidence.run_id)) {
        throw "CGCE-OPS-ID invalid control identifier"
    }
    foreach ($field in @("operator", "server_root", "palserver_executable", "ue4ss_root")) {
        if ($evidence.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($evidence.$field)) {
            throw "CGCE-OPS-CONTROL non-empty control field required"
        }
    }
    Assert-CgceUniqueStrings $evidence.server_process_paths $false "CGCE-OPS-CONTROL"
    if ($evidence.server_process_paths_complete -isnot [bool] -or
        -not $evidence.server_process_paths_complete) {
        throw "CGCE-OPS-CONTROL exhaustive process paths are required"
    }
    $launcherFound = $false
    foreach ($path in @($evidence.server_process_paths)) {
        Assert-CgceWindowsPathContained $path $evidence.server_root "CGCE-OPS-CONTROL"
        if ($path -ceq $evidence.palserver_executable) {
            $launcherFound = $true
        }
    }
    if (-not $launcherFound) {
        throw "CGCE-OPS-CONTROL exact launcher path is required"
    }
    Assert-CgceWindowsPathContained $evidence.palserver_executable $evidence.server_root "CGCE-OPS-CONTROL"
    Assert-CgceWindowsPathContained $evidence.ue4ss_root $evidence.server_root "CGCE-OPS-CONTROL"
    if ($evidence.ue4ss_version -cne "3.0.1") {
        throw "CGCE-OPS-CONTROL unsupported UE4SS version"
    }
    if (-not (Test-CgceChecksum $evidence.ue4ss_dll_sha256)) {
        throw "CGCE-OPS-CONTROL invalid UE4SS checksum"
    }
    Assert-CgceDenseArray $evidence.listener_ports "CGCE-OPS-CONTROL"
    if (@($evidence.listener_ports).Count -eq 0) {
        throw "CGCE-OPS-CONTROL listener ports are required"
    }
    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($port in @($evidence.listener_ports)) {
        if ($port -isnot [ValueType] -or $port -is [bool] -or
            [decimal]::Truncate([decimal]$port) -ne [decimal]$port -or
            [decimal]$port -lt 1 -or [decimal]$port -gt 65535) {
            throw "CGCE-OPS-CONTROL invalid listener port"
        }
        if (-not $ports.Add([int]$port)) {
            throw "CGCE-OPS-CONTROL duplicate listener port"
        }
    }
    foreach ($field in @(
        "production_restart_disabled",
        "external_access_blocked",
        "players_disconnected"
    )) {
        if ($evidence.$field -isnot [bool] -or -not $evidence.$field) {
            throw "CGCE-OPS-CONTROL safety attestations must be true"
        }
    }
    if (-not (Test-CgceChecksum $evidence.bundle_checksum) -or
        $evidence.bundle_checksum -cne $ExpectedBundleChecksum) {
        throw "CGCE-OPS-CHECKSUM bundle checksum drift"
    }
    $verified = Assert-CgceStrictUtc $evidence.verified_at_utc "CGCE-OPS-CONTROL"
    $validUntil = Assert-CgceStrictUtc $evidence.valid_until_utc "CGCE-OPS-CONTROL"
    if ($validUntil -le $verified -or
        ($validUntil - $verified) -gt [TimeSpan]::FromHours(4)) {
        throw "CGCE-OPS-CONTROL invalid control validity window"
    }
    $now = $NowUtc.ToUniversalTime()
    if ($now -lt $verified -or $now -gt $validUntil) {
        throw "CGCE-OPS-CONTROL-EXPIRED control evidence is outside its validity window"
    }
    return $evidence
}

function Get-CgceHandoffRelativeFiles([string]$HandoffRoot) {
    $rootFull = [System.IO.Path]::GetFullPath($HandoffRoot).TrimEnd('\', '/')
    $rootItem = Get-Item -LiteralPath $HandoffRoot -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "CGCE-OPS-CHECKSUM handoff root reparse point is forbidden"
    }
    $pending = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $pending.Enqueue($rootItem)
    $files = New-Object System.Collections.Generic.List[string]
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CGCE-OPS-CHECKSUM handoff reparse point is forbidden"
            }
            if ($item.PSIsContainer) {
                $pending.Enqueue($item)
            } else {
                $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
                if ($relative -cne "source-manifest.sha256") {
                    $null = $files.Add($relative)
                }
            }
        }
    }
    return $files.ToArray()
}

function Assert-CgceHandoffSource(
    [string]$HandoffRoot,
    [string]$ManifestPath,
    [string]$ExpectedManifestChecksum
) {
    if (-not (Test-Path -LiteralPath $HandoffRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "CGCE-OPS-CHECKSUM handoff source is missing"
    }
    $manifestItem = Get-Item -LiteralPath $ManifestPath -Force
    if (($manifestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "CGCE-OPS-CHECKSUM manifest reparse point is forbidden"
    }
    $expectedManifestPath = Join-Path $HandoffRoot "source-manifest.sha256"
    if (-not ([System.IO.Path]::GetFullPath($ManifestPath)).Equals(
        [System.IO.Path]::GetFullPath($expectedManifestPath),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "CGCE-OPS-CHECKSUM manifest path drift"
    }
    if (-not (Test-CgceChecksum $ExpectedManifestChecksum) -or
        (Get-CgceSha256 -Path $ManifestPath) -cne
        $ExpectedManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }
    $bytes = [System.IO.File]::ReadAllBytes($ManifestPath)
    if ([Array]::IndexOf($bytes, [byte]0x0d) -ge 0) {
        throw "CGCE-OPS-CHECKSUM manifest CR is forbidden"
    }
    try {
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString($bytes)
    } catch {
        throw "CGCE-OPS-CHECKSUM manifest must be UTF-8"
    }
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "CGCE-OPS-CHECKSUM manifest final newline is required"
    }
    $lines = @($text.Substring(0, $text.Length - 1).Split("`n"))
    if ($lines.Count -ne $script:CgceHandoffPaths.Count) {
        throw "CGCE-OPS-CHECKSUM handoff manifest exact entry set required"
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $lines.Count; $index += 1) {
        $line = $lines[$index]
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)\z') {
            throw "CGCE-OPS-CHECKSUM malformed handoff manifest record"
        }
        $checksum = $Matches[1]
        $relative = $Matches[2]
        if ($relative -cne $script:CgceHandoffPaths[$index] -or
            -not $seen.Add($relative) -or
            $relative.Contains('\') -or $relative.StartsWith('/') -or
            $relative.StartsWith('//') -or $relative -cmatch '^[A-Za-z]:' -or
            $relative -cmatch '(^|/)\.{1,2}(?:/|\z)' -or
            $relative -cmatch '//') {
            throw "CGCE-OPS-CHECKSUM invalid, unknown, missing, duplicate, or unsorted handoff path"
        }
        $nativePath = Join-Path $HandoffRoot ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) {
            throw "CGCE-OPS-CHECKSUM missing handoff payload"
        }
        $item = Get-Item -LiteralPath $nativePath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CGCE-OPS-CHECKSUM handoff reparse point is forbidden"
        }
        if ((Get-CgceSha256 $nativePath) -cne $checksum) {
            throw "CGCE-OPS-CHECKSUM handoff payload drift"
        }
        $cursor = $item.Directory
        while ($null -ne $cursor -and
            -not $cursor.FullName.Equals(
                [System.IO.Path]::GetFullPath($HandoffRoot),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CGCE-OPS-CHECKSUM handoff reparse point is forbidden"
            }
            $cursor = $cursor.Parent
        }
    }
    $actualPayload = @(Get-CgceHandoffRelativeFiles $HandoffRoot)
    [Array]::Sort($actualPayload, [StringComparer]::Ordinal)
    if ($actualPayload.Count -ne $script:CgceHandoffPaths.Count) {
        throw "CGCE-OPS-CHECKSUM unallowlisted handoff payload"
    }
    for ($index = 0; $index -lt $actualPayload.Count; $index += 1) {
        if ($actualPayload[$index] -cne $script:CgceHandoffPaths[$index]) {
            throw "CGCE-OPS-CHECKSUM unallowlisted handoff payload"
        }
    }
    if ((Get-CgceSha256 -Path $ManifestPath) -cne
        $ExpectedManifestChecksum) {
        throw "CGCE-OPS-CHECKSUM source manifest authority drift"
    }
}

function Assert-CgceStateShape($State) {
    Assert-CgceExactKeys $State $script:CgceStateKeys "CGCE-OPS-JSON"
    if ($State.schema_version -cne "1.0" -or
        $State.kind -cne "cgce_windows_discovery_run_state") {
        throw "CGCE-OPS-JSON unsupported run-state schema"
    }
    if (-not (Test-CgceRunId $State.run_id) -or
        -not (Test-CgceMaintenanceId $State.maintenance_id)) {
        throw "CGCE-OPS-ID invalid run-state identifier"
    }
    if ($State.revision -isnot [ValueType] -or $State.revision -is [bool] -or
        [decimal]::Truncate([decimal]$State.revision) -ne [decimal]$State.revision -or
        [decimal]$State.revision -lt 0) {
        throw "CGCE-OPS-PHASE invalid revision"
    }
    $phaseIndex = [Array]::IndexOf($script:CgcePhases, [string]$State.phase)
    if ($phaseIndex -lt 0 -or @("ACTIVE", "SUCCEEDED", "BLOCKED") -cnotcontains $State.outcome) {
        throw "CGCE-OPS-PHASE invalid phase or outcome"
    }
    if (($State.outcome -ceq "SUCCEEDED" -and $State.phase -cne "EXPORTED") -or
        ($State.phase -ceq "EXPORTED" -and $State.outcome -cne "SUCCEEDED")) {
        throw "CGCE-OPS-PHASE outcome is incompatible with phase"
    }
    $created = Assert-CgceStrictUtc $State.created_at_utc "CGCE-OPS-JSON"
    $updated = Assert-CgceStrictUtc $State.updated_at_utc "CGCE-OPS-JSON"
    if ($updated -lt $created) {
        throw "CGCE-OPS-PHASE updated time precedes creation"
    }
    foreach ($field in @(
        "bundle_checksum",
        "control_evidence_checksum",
        "palserver_executable_checksum",
        "ue4ss_dll_checksum",
        "probe_receipt_checksum",
        "process_launch_receipt_checksum",
        "process_result_receipt_checksum",
        "capture_inventory_checksum"
    )) {
        if ($null -ne $State.$field -and -not (Test-CgceChecksum $State.$field)) {
            throw "CGCE-OPS-CHECKSUM invalid run-state checksum"
        }
    }
    if (-not (Test-CgceChecksum $State.source_manifest_checksum)) {
        throw "CGCE-OPS-CHECKSUM invalid source manifest checksum"
    }
    foreach ($field in @("palserver_executable")) {
        if ($null -ne $State.$field -and
            ($State.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($State.$field))) {
            throw "CGCE-OPS-JSON invalid run-state string"
        }
    }
    if ($null -ne $State.ue4ss_version -and
        ($State.ue4ss_version -isnot [string] -or
            $State.ue4ss_version -cne "3.0.1")) {
        throw "CGCE-OPS-JSON unsupported run-state UE4SS version"
    }
    Assert-CgceUniqueStrings $State.server_process_paths $true "CGCE-OPS-JSON"
    Assert-CgceDenseArray $State.listener_ports "CGCE-OPS-JSON"
    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($port in @($State.listener_ports)) {
        if ($port -isnot [ValueType] -or $port -is [bool] -or
            [decimal]::Truncate([decimal]$port) -ne [decimal]$port -or
            [decimal]$port -lt 1 -or [decimal]$port -gt 65535 -or
            -not $ports.Add([int]$port)) {
            throw "CGCE-OPS-JSON invalid run-state listener ports"
        }
    }
    Assert-CgceExactKeys $State.paths $script:CgcePathKeys "CGCE-OPS-JSON"
    foreach ($key in $script:CgcePathKeys) {
        if ($State.paths.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($State.paths.$key)) {
            throw "CGCE-OPS-JSON every run path is required"
        }
    }
    Assert-CgceExactKeys $State.inventory_checksums @("original", "backup", "clone", "restored") "CGCE-OPS-JSON"
    foreach ($key in @("original", "backup", "clone", "restored")) {
        if ($null -ne $State.inventory_checksums.$key -and
            -not (Test-CgceChecksum $State.inventory_checksums.$key)) {
            throw "CGCE-OPS-CHECKSUM invalid inventory checksum"
        }
    }
    Assert-CgceDenseArray $State.errors "CGCE-OPS-JSON"
    foreach ($errorRecord in @($State.errors)) {
        Assert-CgceExactKeys $errorRecord @("code", "at_utc") "CGCE-OPS-JSON"
        if ($errorRecord.code -isnot [string] -or
            $errorRecord.code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+\z') {
            throw "CGCE-OPS-JSON invalid stable error code"
        }
        $null = Assert-CgceStrictUtc $errorRecord.at_utc "CGCE-OPS-JSON"
    }
    $compatibility = @(
        @("probe_receipt_checksum", 4),
        @("process_launch_receipt_checksum", 5),
        @("process_result_receipt_checksum", 6),
        @("capture_inventory_checksum", 6)
    )
    foreach ($rule in $compatibility) {
        $fieldName = [string]$rule[0]
        if ($phaseIndex -lt [int]$rule[1] -and $null -ne $State.$fieldName) {
            throw "CGCE-OPS-PHASE receipt is incompatible with phase"
        }
    }
    $inventoryCompatibility = @(
        @("backup", 1),
        @("clone", 3),
        @("restored", 8)
    )
    foreach ($rule in $inventoryCompatibility) {
        $inventoryName = [string]$rule[0]
        if ($phaseIndex -lt [int]$rule[1] -and
            $null -ne $State.inventory_checksums.$inventoryName) {
            throw "CGCE-OPS-PHASE inventory is incompatible with phase"
        }
    }
}

function Test-CgceRecoverySourceEvidence($State, [string]$SourcePhase) {
    $requiresBackup = @(
        "BACKUP_VERIFIED",
        "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE",
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED"
    ) -contains $SourcePhase
    $requiresClone = @(
        "CLONE_ACTIVE",
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED"
    ) -contains $SourcePhase
    $requiresProbe = @(
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED"
    ) -contains $SourcePhase
    $requiresCapture = $SourcePhase -ceq "CAPTURED"
    if (@(
            "CREATED",
            "BACKUP_VERIFIED",
            "ORIGINAL_DEACTIVATED",
            "CLONE_ACTIVE",
            "PROBE_STAGED",
            "RUNNING",
            "CAPTURED"
        ) -cnotcontains $SourcePhase) {
        return $false
    }
    return (
        $null -ne $State.inventory_checksums.original -and
        (($null -ne $State.inventory_checksums.backup) -eq $requiresBackup) -and
        (($null -ne $State.inventory_checksums.clone) -eq $requiresClone) -and
        (($null -ne $State.probe_receipt_checksum) -eq $requiresProbe) -and
        (($null -ne $State.process_launch_receipt_checksum) -eq
            $requiresCapture) -and
        (($null -ne $State.process_result_receipt_checksum) -eq
            $requiresCapture) -and
        (($null -ne $State.capture_inventory_checksum) -eq $requiresCapture)
    )
}

function Assert-CgceRecoveryCheckpointEvidence(
    $State,
    [bool]$RequiresRestored
) {
    if ((($null -ne $State.inventory_checksums.restored) -ne
            $RequiresRestored)) {
        throw "CGCE-OPS-PHASE recovery restored evidence drift"
    }
    foreach ($sourcePhase in @(
        "CREATED",
        "BACKUP_VERIFIED",
        "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE",
        "PROBE_STAGED",
        "RUNNING",
        "CAPTURED"
    )) {
        if (Test-CgceRecoverySourceEvidence $State $sourcePhase) {
            return
        }
    }
    throw "CGCE-OPS-PHASE recovery source evidence has gaps or foreign fields"
}

function Assert-CgceCheckpointEvidence($State) {
    switch ($State.phase) {
        "CREATED" {
            if (-not (Test-CgceRecoverySourceEvidence $State "CREATED") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid CREATED evidence"
            }
        }
        "BACKUP_VERIFIED" {
            if (-not (Test-CgceRecoverySourceEvidence `
                    $State "BACKUP_VERIFIED") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid BACKUP_VERIFIED evidence"
            }
        }
        "ORIGINAL_DEACTIVATED" {
            if (-not (Test-CgceRecoverySourceEvidence `
                    $State "ORIGINAL_DEACTIVATED") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid ORIGINAL_DEACTIVATED evidence"
            }
        }
        "CLONE_ACTIVE" {
            if (-not (Test-CgceRecoverySourceEvidence $State "CLONE_ACTIVE") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid CLONE_ACTIVE evidence"
            }
        }
        "PROBE_STAGED" {
            if (-not (Test-CgceRecoverySourceEvidence $State "PROBE_STAGED") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid PROBE_STAGED evidence"
            }
        }
        "RUNNING" {
            if (-not (Test-CgceRecoverySourceEvidence $State "RUNNING") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid RUNNING evidence"
            }
        }
        "CAPTURED" {
            if (-not (Test-CgceRecoverySourceEvidence $State "CAPTURED") -or
                $null -ne $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid CAPTURED evidence"
            }
        }
        "RESTORING" {
            Assert-CgceRecoveryCheckpointEvidence $State $false
        }
        "RESTORED" {
            Assert-CgceRecoveryCheckpointEvidence $State $true
        }
        "EXPORTED" {
            if (-not (Test-CgceRecoverySourceEvidence $State "CAPTURED") -or
                $null -eq $State.inventory_checksums.restored) {
                throw "CGCE-OPS-PHASE invalid EXPORTED evidence"
            }
        }
        default {
            throw "CGCE-OPS-PHASE invalid checkpoint phase"
        }
    }
}

function Assert-CgceGenesisState($State) {
    Assert-CgceStateShape $State
    if ($State.phase -cne "CREATED" -or
        [int64]$State.revision -ne 0 -or
        $State.outcome -cne "ACTIVE" -or
        @($State.errors).Count -ne 0 -or
        -not (Test-CgceRecoverySourceEvidence $State "CREATED") -or
        $null -ne $State.inventory_checksums.restored) {
        throw "CGCE-OPS-PHASE genesis must be pristine CREATED authority"
    }
}

function Get-CgceStateChecksumValue($State, [string]$Name) {
    switch ($Name) {
        "inventory.original" { return $State.inventory_checksums.original }
        "inventory.backup" { return $State.inventory_checksums.backup }
        "inventory.clone" { return $State.inventory_checksums.clone }
        "inventory.restored" { return $State.inventory_checksums.restored }
        "probe" { return $State.probe_receipt_checksum }
        "process.launch" { return $State.process_launch_receipt_checksum }
        "process.result" { return $State.process_result_receipt_checksum }
        "capture" { return $State.capture_inventory_checksum }
        default { throw "CGCE-OPS-JSON unknown state checksum field" }
    }
}

function Assert-CgceImmutableStateChecksums($Old, $Next) {
    foreach ($name in @(
        "inventory.original",
        "inventory.backup",
        "inventory.clone",
        "inventory.restored",
        "probe",
        "process.launch",
        "process.result",
        "capture"
    )) {
        $oldValue = Get-CgceStateChecksumValue $Old $name
        $nextValue = Get-CgceStateChecksumValue $Next $name
        if ($null -ne $oldValue -and $oldValue -cne $nextValue) {
            throw "CGCE-OPS-CHECKSUM immutable state checksum drift"
        }
    }
}

function Assert-CgceExactStateChecksums($Old, $Next) {
    foreach ($name in @(
        "inventory.original",
        "inventory.backup",
        "inventory.clone",
        "inventory.restored",
        "probe",
        "process.launch",
        "process.result",
        "capture"
    )) {
        if ((Get-CgceStateChecksumValue $Old $name) -cne
            (Get-CgceStateChecksumValue $Next $name)) {
            throw "CGCE-OPS-CHECKSUM blocked state checksum drift"
        }
    }
}

function Assert-CgceTransitionCheckpointFields(
    $Old,
    $Next,
    [string]$ExpectedPhase
) {
    $allowed = switch ($ExpectedPhase) {
        "CREATED" { @("inventory.backup") }
        "BACKUP_VERIFIED" { @() }
        "ORIGINAL_DEACTIVATED" { @("inventory.clone") }
        "CLONE_ACTIVE" { @("probe") }
        "PROBE_STAGED" { @() }
        "RUNNING" { @("process.launch", "process.result", "capture") }
        "RESTORED" { @() }
        default { throw "CGCE-OPS-PHASE unsupported normal transition" }
    }
    foreach ($name in @(
        "inventory.original",
        "inventory.backup",
        "inventory.clone",
        "inventory.restored",
        "probe",
        "process.launch",
        "process.result",
        "capture"
    )) {
        $oldValue = Get-CgceStateChecksumValue $Old $name
        $nextValue = Get-CgceStateChecksumValue $Next $name
        if ($null -eq $oldValue -and
            $null -ne $nextValue -and
            $allowed -cnotcontains $name) {
            throw "CGCE-OPS-PHASE transition introduced a foreign checkpoint"
        }
    }
}

function New-CgceRunState([string]$RunId, [string]$MaintenanceId, $Paths) {
    if (-not (Test-CgceRunId $RunId) -or -not (Test-CgceMaintenanceId $MaintenanceId)) {
        throw "CGCE-OPS-ID invalid run-state identifier"
    }
    Assert-CgceExactKeys $Paths $script:CgcePathKeys "CGCE-OPS-JSON"
    foreach ($key in $script:CgcePathKeys) {
        if ($Paths.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($Paths.$key)) {
            throw "CGCE-OPS-JSON every run path is required"
        }
    }
    $now = [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    return [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_run_state"
        revision = 0
        run_id = $RunId
        maintenance_id = $MaintenanceId
        phase = "CREATED"
        outcome = "ACTIVE"
        created_at_utc = $now
        updated_at_utc = $now
        bundle_checksum = $null
        control_evidence_checksum = $null
        source_manifest_checksum = $null
        palserver_executable = $null
        palserver_executable_checksum = $null
        ue4ss_version = $null
        server_process_paths = [object[]]@()
        ue4ss_dll_checksum = $null
        listener_ports = [object[]]@()
        paths = $Paths
        inventory_checksums = [pscustomobject][ordered]@{
            original = $null
            backup = $null
            clone = $null
            restored = $null
        }
        probe_receipt_checksum = $null
        process_launch_receipt_checksum = $null
        process_result_receipt_checksum = $null
        capture_inventory_checksum = $null
        errors = [object[]]@()
    }
}

function Compare-CgceJsonValue($Expected, $Actual) {
    $expectedJson = $Expected | ConvertTo-Json -Depth 12 -Compress
    $actualJson = $Actual | ConvertTo-Json -Depth 12 -Compress
    return $expectedJson -ceq $actualJson
}

function Assert-CgceStateIdentity($Genesis, $Current) {
    foreach ($field in @(
        "run_id",
        "maintenance_id",
        "created_at_utc",
        "bundle_checksum",
        "control_evidence_checksum",
        "source_manifest_checksum",
        "palserver_executable",
        "palserver_executable_checksum",
        "ue4ss_version",
        "ue4ss_dll_checksum"
    )) {
        if ($Genesis.$field -cne $Current.$field) {
            throw "CGCE-OPS-CHECKSUM run-state identity drift"
        }
    }
    foreach ($field in @("server_process_paths", "listener_ports", "paths")) {
        if (-not (Compare-CgceJsonValue $Genesis.$field $Current.$field)) {
            throw "CGCE-OPS-CHECKSUM run-state identity drift"
        }
    }
    if ([decimal]$Current.revision -lt [decimal]$Genesis.revision) {
        throw "CGCE-OPS-PHASE non-monotonic revision"
    }
    if ($Genesis.inventory_checksums.original -cne
        $Current.inventory_checksums.original) {
        throw "CGCE-OPS-CHECKSUM original inventory identity drift"
    }
}

function Read-CgceRunState([string]$RunRoot, [string]$RunId) {
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    $runDirectory = Join-Path $RunRoot $RunId
    $statePath = Join-Path $runDirectory "run-state.json"
    $genesisPath = Join-Path $runDirectory "run-state.genesis.json"
    $state = Read-CgceJsonObject -Path $statePath
    $genesis = Read-CgceJsonObject -Path $genesisPath
    Assert-CgceStateShape $state
    Assert-CgceCheckpointEvidence $state
    Assert-CgceGenesisState $genesis
    if ($state.run_id -cne $RunId -or $genesis.run_id -cne $RunId) {
        throw "CGCE-OPS-ID run-state path identity mismatch"
    }
    Assert-CgceStateIdentity $genesis $state
    $expectedRunRoot = Get-CgceCanonicalForIdentity $RunRoot
    $stateRunRoot = Get-CgceCanonicalForIdentity $state.paths.run_root
    $expectedRunDirectory = Get-CgceCanonicalForIdentity $runDirectory
    $stateRunDirectory = Get-CgceCanonicalForIdentity $state.paths.run_directory
    $expectedStatePath = Get-CgceCanonicalForIdentity $statePath
    $recordedStatePath = Get-CgceCanonicalForIdentity $state.paths.state
    $expectedGenesisPath = Get-CgceCanonicalForIdentity $genesisPath
    $recordedGenesisPath = Get-CgceCanonicalForIdentity $state.paths.genesis_state
    if (-not $expectedRunRoot.Equals($stateRunRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $expectedRunDirectory.Equals($stateRunDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        -not $expectedStatePath.Equals($recordedStatePath, [StringComparison]::OrdinalIgnoreCase) -or
        -not $expectedGenesisPath.Equals($recordedGenesisPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CGCE-OPS-ID run-state path identity mismatch"
    }
    return $state
}

function Set-CgceRunPhase($State, [string]$ExpectedPhase, [string]$NextPhase) {
    if ($State.phase -cne $ExpectedPhase -or
        -not $script:CgceNextPhase.ContainsKey($ExpectedPhase) -or
        $script:CgceNextPhase[$ExpectedPhase] -cne $NextPhase) {
        throw "CGCE-OPS-PHASE invalid transition"
    }
    $State.phase = $NextPhase
    return $State
}

function ConvertTo-CgceJsonText($Value) {
    return ($Value | ConvertTo-Json -Depth 12)
}

function Get-CgceTextSha256([string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Write-CgceJsonAtomic(
    $Value,
    [string]$Path
) {
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent) -or
        -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "CGCE-OPS-JSON output parent is missing"
    }
    $temp = Join-Path $parent ((Split-Path -Leaf $Path) + ".tmp")
    if (Test-Path -LiteralPath $temp) {
        throw "CGCE-OPS-OUTPUT-EXISTS temp exists"
    }
    if (Test-Path -LiteralPath $Path) {
        throw "CGCE-OPS-OUTPUT-EXISTS destination exists"
    }
    $json = ConvertTo-CgceJsonText $Value
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        throw "CGCE-OPS-OUTPUT-EXISTS destination exists"
    }
    [System.IO.File]::Move($temp, $Path)
}

function Invoke-CgceFileReplaceNoBackup(
    [string]$SourceFileName,
    [string]$DestinationFileName
) {
    if ($null -eq $script:CgceFileReplaceMethod) {
        $parameterTypes = [Type[]]@(
            [string],
            [string],
            [string],
            [bool]
        )
        $script:CgceFileReplaceMethod = [System.IO.File].GetMethod(
            "Replace",
            [System.Reflection.BindingFlags]::Public -bor
                [System.Reflection.BindingFlags]::Static,
            $null,
            $parameterTypes,
            $null
        )
        if ($null -eq $script:CgceFileReplaceMethod) {
            throw "CGCE-OPS-JSON exact file replacement overload is unavailable"
        }
    }
    $arguments = [object[]]@(
        $SourceFileName
        $DestinationFileName
        $null
        $true
    )
    try {
        $null = $script:CgceFileReplaceMethod.Invoke($null, $arguments)
    } catch [System.Reflection.TargetInvocationException] {
        if ($null -ne $_.Exception.InnerException) {
            throw $_.Exception.InnerException
        }
        throw
    }
}

function Replace-CgceRunStateJson(
    $Value,
    [string]$Path,
    [string]$ExpectedStateChecksum
) {
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent) -or
        -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "CGCE-OPS-JSON output parent is missing"
    }
    if ((Split-Path -Leaf $Path) -cne "run-state.json") {
        throw "CGCE-OPS-CHECKSUM state replacement is restricted to run-state.json"
    }
    if (-not (Test-CgceChecksum $ExpectedStateChecksum)) {
        throw "CGCE-OPS-CHECKSUM invalid state replacement checksum"
    }
    $temp = Join-Path $parent ((Split-Path -Leaf $Path) + ".tmp")
    if (Test-Path -LiteralPath $temp) {
        throw "CGCE-OPS-OUTPUT-EXISTS temp exists"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if (Test-Path -LiteralPath $Path) {
            throw "CGCE-OPS-OUTPUT-EXISTS destination exists"
        }
        throw "CGCE-OPS-CHECKSUM expected existing run-state"
    }
    if ((Get-CgceSha256 -Path $Path) -cne $ExpectedStateChecksum) {
        throw "CGCE-OPS-CHECKSUM state replacement mismatch"
    }
    $existingState = Read-CgceJsonObject -Path $Path
    Assert-CgceStateShape $existingState
    Assert-CgceStateShape $Value
    Assert-CgceCheckpointEvidence $existingState
    Assert-CgceCheckpointEvidence $Value

    $json = ConvertTo-CgceJsonText $Value
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8NoBom)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-CgceSha256 -Path $Path) -cne $ExpectedStateChecksum) {
        throw "CGCE-OPS-CHECKSUM state replacement mismatch"
    }
    Invoke-CgceFileReplaceNoBackup `
        -SourceFileName $temp `
        -DestinationFileName $Path
}

function Write-CgceRunState(
    $State,
    [string]$StatePath,
    [string]$ExpectedPhase
) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "CGCE-OPS-JSON run-state is missing"
    }
    $oldChecksum = Get-CgceSha256 -Path $StatePath
    $old = Read-CgceJsonObject -Path $StatePath
    Assert-CgceStateShape $old
    Assert-CgceStateShape $State
    Assert-CgceCheckpointEvidence $old
    Assert-CgceCheckpointEvidence $State
    $genesis = Read-CgceJsonObject -Path $old.paths.genesis_state
    Assert-CgceGenesisState $genesis
    Assert-CgceStateIdentity $genesis $old
    if ($old.phase -cne $ExpectedPhase) {
        throw "CGCE-OPS-PHASE current phase drift"
    }
    $recordedStatePath = Get-CgceCanonicalForIdentity $old.paths.state
    $actualStatePath = Get-CgceCanonicalForIdentity $StatePath
    if (-not $recordedStatePath.Equals($actualStatePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CGCE-OPS-ID run-state path identity mismatch"
    }
    if ($old.run_id -cne $State.run_id -or
        $old.maintenance_id -cne $State.maintenance_id) {
        throw "CGCE-OPS-ID run-state identity drift"
    }
    foreach ($field in @(
        "created_at_utc",
        "bundle_checksum",
        "control_evidence_checksum",
        "source_manifest_checksum",
        "palserver_executable",
        "palserver_executable_checksum",
        "ue4ss_version",
        "server_process_paths",
        "ue4ss_dll_checksum",
        "listener_ports",
        "paths"
    )) {
        if (-not (Compare-CgceJsonValue $old.$field $State.$field)) {
            throw "CGCE-OPS-CHECKSUM run-state identity drift"
        }
    }
    Assert-CgceImmutableStateChecksums $old $State
    $expectedOutcome = if ($State.phase -ceq "EXPORTED") {
        "SUCCEEDED"
    } else {
        "ACTIVE"
    }
    $validTransition = $script:CgceNextPhase.ContainsKey($ExpectedPhase) -and
        $script:CgceNextPhase[$ExpectedPhase] -ceq $State.phase -and
        $old.outcome -ceq "ACTIVE" -and
        $State.outcome -ceq $expectedOutcome
    $validBlock = $ExpectedPhase -cne "RESTORING" -and
        $State.phase -ceq $ExpectedPhase -and
        $old.outcome -ceq "ACTIVE" -and
        $State.outcome -ceq "BLOCKED"
    if (-not $validTransition -and -not $validBlock) {
        throw "CGCE-OPS-PHASE invalid persisted transition"
    }
    if ($validTransition) {
        if (-not (Compare-CgceJsonValue $old.errors $State.errors)) {
            throw "CGCE-OPS-PHASE normal transition cannot change errors"
        }
        Assert-CgceTransitionCheckpointFields $old $State $ExpectedPhase
    } else {
        Assert-CgceExactStateChecksums $old $State
        if (@($State.errors).Count -ne (@($old.errors).Count + 1)) {
            throw "CGCE-OPS-PHASE blocked transition must append one error"
        }
        for ($index = 0; $index -lt @($old.errors).Count; $index += 1) {
            if (-not (Compare-CgceJsonValue `
                    $old.errors[$index] `
                    $State.errors[$index])) {
                throw "CGCE-OPS-PHASE blocked errors are append-only"
            }
        }
    }
    $State.revision = [int64]$old.revision + 1
    $State.updated_at_utc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    Assert-CgceStateShape $State
    $expectedText = ConvertTo-CgceJsonText $State
    $expectedChecksum = Get-CgceTextSha256 $expectedText
    $persistenceContext = [pscustomobject]@{
        existing = $old
        candidate = $State
        state_path = $StatePath
        expected_existing_checksum = $oldChecksum
        expected_candidate_checksum = $expectedChecksum
    }
    if ($null -ne $script:CgceTestStatePersistenceSeam) {
        $null = & $script:CgceTestStatePersistenceSeam `
            "before-state-replace" `
            $persistenceContext
    }
    Replace-CgceRunStateJson `
        -Value $State `
        -Path $StatePath `
        -ExpectedStateChecksum $oldChecksum
    if ($null -ne $script:CgceTestStatePersistenceSeam) {
        $null = & $script:CgceTestStatePersistenceSeam `
            "after-state-replace" `
            $persistenceContext
    }
    Confirm-CgceRunStateReadBack `
        -StatePath $StatePath `
        -ExpectedChecksum $expectedChecksum `
        -ExpectedRevision ([int64]$State.revision) `
        -ExpectedPhase $State.phase
    if ($null -ne $script:CgceTestStatePersistenceSeam) {
        $null = & $script:CgceTestStatePersistenceSeam `
            "after-state-readback" `
            $persistenceContext
    }
}

function Confirm-CgceRunStateReadBack(
    [string]$StatePath,
    [string]$ExpectedChecksum,
    [int64]$ExpectedRevision,
    [string]$ExpectedPhase
) {
    $readBack = Read-CgceRunStateAfterReplace -Path $StatePath
    Assert-CgceStateShape $readBack
    Assert-CgceCheckpointEvidence $readBack
    $actualChecksum = Get-CgceSha256 -Path $StatePath
    if ($actualChecksum -cne $expectedChecksum -or
        [int64]$readBack.revision -ne $ExpectedRevision -or
        $readBack.phase -cne $ExpectedPhase) {
        throw "CGCE-OPS-CHECKSUM run-state read-back mismatch"
    }
}

function Read-CgceRunStateAfterReplace([string]$Path) {
    return Read-CgceJsonObject -Path $Path
}

function Get-CgceCanonicalForIdentity([string]$Path) {
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        throw "CGCE-OPS-CONTROL invalid marker path"
    }
}

function Write-CgceActiveRunMarker(
    $State,
    [string]$GenesisStateChecksum,
    [string]$Path
) {
    Assert-CgceStateShape $State
    Assert-CgceCheckpointEvidence $State
    if (-not (Test-CgceChecksum $GenesisStateChecksum)) {
        throw "CGCE-OPS-CHECKSUM invalid genesis checksum"
    }
    $expectedPath = Get-CgceCanonicalForIdentity $State.paths.active_run_marker
    $actualPath = Get-CgceCanonicalForIdentity $Path
    if (-not $expectedPath.Equals(
            $actualPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-CONTROL active marker path drift"
    }
    if ((Get-CgceSha256 -Path $State.paths.genesis_state) -cne
        $GenesisStateChecksum) {
        throw "CGCE-OPS-CHECKSUM immutable genesis drift"
    }
    $genesis = Read-CgceJsonObject -Path $State.paths.genesis_state
    $current = Read-CgceJsonObject -Path $State.paths.state
    Assert-CgceGenesisState $genesis
    Assert-CgceStateShape $current
    Assert-CgceCheckpointEvidence $current
    Assert-CgceStateIdentity $genesis $current
    if ((Get-CgceSha256 -Path $State.paths.state) -cne
        $GenesisStateChecksum -or
        -not (Compare-CgceJsonValue $genesis $current)) {
        throw "CGCE-OPS-CHECKSUM marker requires byte-identical genesis/current"
    }
    if (-not (Compare-CgceJsonValue $State $current)) {
        throw "CGCE-OPS-CHECKSUM stale marker state"
    }
    $marker = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_run_marker"
        run_id = $State.run_id
        run_root = $State.paths.run_root
        genesis_state_checksum = $GenesisStateChecksum
    }
    Write-CgceJsonAtomic -Value $marker -Path $Path
    $readBack = Read-CgceJsonObject -Path $Path
    Assert-CgceExactKeys `
        $readBack `
        @("schema_version", "kind", "run_id", "run_root", "genesis_state_checksum") `
        "CGCE-OPS-CONTROL"
    if (-not (Compare-CgceJsonValue $marker $readBack)) {
        throw "CGCE-OPS-CHECKSUM active marker read-back drift"
    }
    Assert-CgceRunMarker -State $State
}

function Block-CgceRunState(
    [string]$StatePath,
    [string]$Code
) {
    if ($Code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+\z') {
        throw "CGCE-OPS-BLOCKED invalid stable error code"
    }
    $state = Read-CgceJsonObject -Path $StatePath
    Assert-CgceStateShape $state
    Assert-CgceCheckpointEvidence $state
    $recordedStatePath = Get-CgceCanonicalForIdentity $state.paths.state
    $actualStatePath = Get-CgceCanonicalForIdentity $StatePath
    if (-not $recordedStatePath.Equals(
            $actualStatePath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-ID run-state path identity mismatch"
    }
    $genesis = Read-CgceJsonObject -Path $state.paths.genesis_state
    Assert-CgceGenesisState $genesis
    Assert-CgceStateIdentity $genesis $state
    if ($state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE only ACTIVE state can become BLOCKED"
    }
    Assert-CgceRunMarker -State $state
    $state = Read-CgceJsonObject -Path $StatePath
    Assert-CgceStateShape $state
    Assert-CgceCheckpointEvidence $state
    Assert-CgceStateIdentity $genesis $state
    if ($state.phase -ceq "RESTORING") {
        throw "CGCE-OPS-PHASE recovery blocking requires fixed-purpose authority"
    }
    if ($state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE only ACTIVE state can become BLOCKED"
    }
    Assert-CgceRunMarker -State $state
    $errors = New-Object 'System.Collections.Generic.List[object]'
    foreach ($existing in @($state.errors)) {
        $null = $errors.Add($existing)
    }
    $null = $errors.Add([pscustomobject][ordered]@{
        code = $Code
        at_utc = [DateTime]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    })
    $state.errors = [object[]]$errors.ToArray()
    $state.outcome = "BLOCKED"
    $phase = $state.phase
    Write-CgceRunState `
        -State $state `
        -StatePath $StatePath `
        -ExpectedPhase $phase
    $readBack = Read-CgceJsonObject -Path $StatePath
    Assert-CgceStateShape $readBack
    Assert-CgceCheckpointEvidence $readBack
    Assert-CgceStateIdentity $genesis $readBack
    if ($readBack.outcome -cne "BLOCKED" -or
        $readBack.phase -cne $phase -or
        @($readBack.errors).Count -ne $errors.Count -or
        $readBack.errors[$errors.Count - 1].code -cne $Code) {
        throw "CGCE-OPS-CHECKSUM blocked state read-back drift"
    }
    return $readBack
}

function Assert-CgceRunMarker($State, [switch]$AllowCompleted) {
    Assert-CgceStateShape $State
    Assert-CgceCheckpointEvidence $State
    $current = Read-CgceJsonObject -Path $State.paths.state
    Assert-CgceStateShape $current
    Assert-CgceCheckpointEvidence $current
    if (-not (Compare-CgceJsonValue $State $current)) {
        throw "CGCE-OPS-CHECKSUM stale or forged current state"
    }
    $activeExists = Test-Path -LiteralPath $State.paths.active_run_marker -PathType Leaf
    $completedExists = Test-Path -LiteralPath $State.paths.completed_run_marker -PathType Leaf
    if (($activeExists -and $completedExists) -or
        (-not $activeExists -and -not ($AllowCompleted -and $completedExists))) {
        throw "CGCE-OPS-CONTROL exact run marker location required"
    }
    if (-not $AllowCompleted -and -not $activeExists) {
        throw "CGCE-OPS-CONTROL active run marker required"
    }
    $markerPath = if ($activeExists) {
        $State.paths.active_run_marker
    } else {
        $State.paths.completed_run_marker
    }
    $marker = Read-CgceJsonObject -Path $markerPath
    Assert-CgceExactKeys `
        $marker `
        @("schema_version", "kind", "run_id", "run_root", "genesis_state_checksum") `
        "CGCE-OPS-CONTROL"
    if ($marker.schema_version -cne "1.0" -or
        $marker.kind -cne "cgce_windows_discovery_run_marker" -or
        $marker.run_id -cne $State.run_id -or
        -not (Test-CgceChecksum $marker.genesis_state_checksum)) {
        throw "CGCE-OPS-CONTROL run marker identity drift"
    }
    $markerRoot = Get-CgceCanonicalForIdentity $marker.run_root
    $stateRoot = Get-CgceCanonicalForIdentity $State.paths.run_root
    if (-not $markerRoot.Equals($stateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CGCE-OPS-CONTROL run marker root drift"
    }
    $genesisChecksum = Get-CgceSha256 -Path $State.paths.genesis_state
    if ($genesisChecksum -cne $marker.genesis_state_checksum) {
        throw "CGCE-OPS-CHECKSUM immutable genesis drift"
    }
    $genesis = Read-CgceJsonObject -Path $State.paths.genesis_state
    Assert-CgceGenesisState $genesis
    Assert-CgceStateIdentity $genesis $current
    if ($genesis.run_id -cne $State.run_id -or
        $genesis.maintenance_id -cne $State.maintenance_id) {
        throw "CGCE-OPS-ID marker/genesis/current identity mismatch"
    }
    $genesisRoot = Get-CgceCanonicalForIdentity $genesis.paths.run_root
    if (-not $genesisRoot.Equals($stateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CGCE-OPS-CONTROL genesis run root drift"
    }
}

function Enter-CgceExclusiveLock([string]$ServerRoot, [string]$RunId) {
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-ID invalid run identifier"
    }
    if (-not (Test-Path -LiteralPath $ServerRoot -PathType Container)) {
        throw "CGCE-OPS-CONTROL server root is missing"
    }
    $lockPath = Join-Path $ServerRoot ".cgce-discovery.lock"
    try {
        return [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "CGCE-OPS-CONTROL exclusive lock unavailable"
    }
}

# Recovery state transitions deliberately live here, rather than in the
# filesystem or runtime modules.  They are fixed-purpose authority changes:
# callers cannot supply a state object, an activity callback, or a bypass.
function Add-CgceRecoveryUInt32([IO.MemoryStream]$Stream, [uint32]$Value) {
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Add-CgceRecoveryUInt64([IO.MemoryStream]$Stream, [uint64]$Value) {
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Get-CgceInventoryTreeSha256([object[]]$Entries) {
    if ($null -eq $Entries -or $Entries -isnot [System.Array]) {
        throw "CGCE-OPS-INVENTORY dense entries array required"
    }
    $previous = $null
    $seen = New-Object 'Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.MemoryStream
    try {
        $domain = $encoding.GetBytes("CGCE-TREE-1")
        $stream.Write($domain, 0, $domain.Length)
        $stream.WriteByte(0)
        Add-CgceRecoveryUInt32 $stream ([uint32]$Entries.Count)
        foreach ($entry in $Entries) {
            Assert-CgceExactKeys $entry @("relative_path", "length", "sha256") "CGCE-OPS-INVENTORY"
            if ($entry.relative_path -isnot [string] -or
                [string]::IsNullOrWhiteSpace($entry.relative_path) -or
                $entry.relative_path.StartsWith("/") -or
                $entry.relative_path.Contains("\\") -or
                $entry.relative_path.Contains(":") -or
                $entry.relative_path -cmatch '[\x00-\x1f]') {
                throw "CGCE-OPS-INVENTORY invalid relative path"
            }
            foreach ($part in $entry.relative_path.Split('/')) {
                if ($part.Length -eq 0 -or $part -ceq "." -or $part -ceq "..") {
                    throw "CGCE-OPS-INVENTORY invalid relative path"
                }
            }
            if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous, $entry.relative_path) -ge 0) {
                throw "CGCE-OPS-INVENTORY entries must be strictly sorted"
            }
            if (-not $seen.Add($entry.relative_path)) {
                throw "CGCE-OPS-INVENTORY duplicate relative path"
            }
            if ($entry.length -isnot [ValueType] -or $entry.length -is [bool] -or
                [decimal]::Truncate([decimal]$entry.length) -ne [decimal]$entry.length -or
                [decimal]$entry.length -lt 0 -or [decimal]$entry.length -gt [int64]::MaxValue) {
                throw "CGCE-OPS-INVENTORY invalid file length"
            }
            if (-not (Test-CgceChecksum $entry.sha256)) {
                throw "CGCE-OPS-INVENTORY invalid SHA-256"
            }
            $pathBytes = $encoding.GetBytes($entry.relative_path)
            Add-CgceRecoveryUInt32 $stream ([uint32]$pathBytes.Length)
            $stream.Write($pathBytes, 0, $pathBytes.Length)
            Add-CgceRecoveryUInt64 $stream ([uint64][int64]$entry.length)
            $hashBytes = New-Object byte[] 32
            for ($index = 0; $index -lt 32; $index += 1) {
                $hashBytes[$index] = [Convert]::ToByte($entry.sha256.Substring($index * 2, 2), 16)
            }
            $stream.Write($hashBytes, 0, $hashBytes.Length)
            $previous = $entry.relative_path
        }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($stream.ToArray()))).Replace("-", "").ToLowerInvariant()
        } finally { $algorithm.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-CgceRecoveryUtcNow {
    return [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Test-CgceRecoveryInteger(
    $Value,
    [int64]$Minimum,
    [int64]$Maximum
) {
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if (@(
            [TypeCode]::SByte,
            [TypeCode]::Byte,
            [TypeCode]::Int16,
            [TypeCode]::UInt16,
            [TypeCode]::Int32,
            [TypeCode]::UInt32,
            [TypeCode]::Int64,
            [TypeCode]::UInt64,
            [TypeCode]::Decimal
        ) -notcontains $typeCode) {
        return $false
    }
    try {
        $number = [decimal]$Value
        return [decimal]::Truncate($number) -eq $number -and
            $number -ge [decimal]$Minimum -and
            $number -le [decimal]$Maximum
    } catch {
        return $false
    }
}

function Test-CgceRecoveryPathEqual(
    [string]$Left,
    [string]$Right
) {
    $canonicalLeft = Get-CgceCanonicalForIdentity $Left
    $canonicalRight = Get-CgceCanonicalForIdentity $Right
    return $canonicalLeft.Equals(
        $canonicalRight,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-CgceRecoveryBytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-CgceRecoveryFramedStringArraySha256(
    [string]$Domain,
    [string[]]$Values
) {
    if ($null -eq $Values) {
        throw "CGCE-OPS-PROCESS-RECEIPT dense path array required"
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.MemoryStream
    try {
        $domainBytes = $encoding.GetBytes($Domain)
        $stream.Write($domainBytes, 0, $domainBytes.Length)
        $stream.WriteByte(0)
        Add-CgceRecoveryUInt32 $stream ([uint32]$Values.Count)
        foreach ($value in $Values) {
            if ($value -isnot [string]) {
                throw "CGCE-OPS-PROCESS-RECEIPT dense path array required"
            }
            $bytes = $encoding.GetBytes($value)
            Add-CgceRecoveryUInt32 $stream ([uint32]$bytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        return Get-CgceRecoveryBytesSha256 $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Assert-CgceRecoveryExactKeys(
    $Value,
    [string[]]$Keys,
    [string]$Code = "CGCE-OPS-RECOVERY-INTENT"
) {
    Assert-CgceExactKeys $Value $Keys $Code
}

function Assert-CgceRecoveryManualBarrier($State) {
    foreach ($errorRecord in @($State.errors)) {
        if ($errorRecord.code -ceq "CGCE-OPS-MANUAL-RECOVERY") {
            throw "CGCE-OPS-MANUAL-RECOVERY persisted manual recovery barrier"
        }
    }
}

function Get-CgceRecoveryExecutablePaths($State) {
    $values = @($State.server_process_paths)
    if ($values.Count -eq 0 -or $values.Count -gt 4096) {
        throw "CGCE-OPS-PROCESS-QUERY exhaustive executable paths required"
    }
    $paths = New-Object 'Collections.Generic.List[string]'
    $seen = New-Object 'Collections.Generic.HashSet[string]' `
        -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $values) {
        if ($value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt 4096) {
            throw "CGCE-OPS-PROCESS-QUERY invalid executable path"
        }
        try {
            $canonical = Get-CgceCanonicalForIdentity $value
        } catch {
            throw "CGCE-OPS-PROCESS-QUERY invalid executable path"
        }
        if (-not $seen.Add($canonical)) {
            throw "CGCE-OPS-PROCESS-QUERY duplicate executable path"
        }
        $null = $paths.Add($canonical)
    }
    return [string[]]$paths.ToArray()
}

function Get-CgceRecoveryPorts($State) {
    $values = @($State.listener_ports)
    if ($values.Count -eq 0) {
        throw "CGCE-OPS-PORT-QUERY configured ports required"
    }
    $ports = New-Object 'Collections.Generic.List[int]'
    $seen = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($value in $values) {
        if (-not (Test-CgceRecoveryInteger $value 1 65535) -or
            -not $seen.Add([int]$value)) {
            throw "CGCE-OPS-PORT-QUERY invalid configured port"
        }
        $null = $ports.Add([int]$value)
    }
    return [int[]]$ports.ToArray()
}

function Assert-CgceRecoveryProcessReceiptDirectory([string]$ReceiptRoot) {
    if (-not (Test-Path -LiteralPath $ReceiptRoot -PathType Container)) {
        throw "CGCE-OPS-PROCESS-RECEIPT receipt root missing"
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $ReceiptRoot -Force)) {
        if ($child.PSIsContainer -or
            $child.Name -cnotmatch
                '^(?:000-launch|[0-9]{3}-pid|999-result|manual-recovery-required)\.json\z') {
            throw "CGCE-OPS-PROCESS-RECEIPT unknown process receipt child"
        }
    }
}

function Read-CgceRecoveryLaunchReceipt(
    [string]$Path,
    $State,
    [string[]]$CanonicalPaths
) {
    try {
        $value = Read-CgceJsonObject $Path
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch receipt"
    }
    Assert-CgceRecoveryExactKeys $value @(
        "schema_version", "kind", "run_id", "sequence", "created_at_utc",
        "executable_path", "executable_sha256", "working_directory",
        "allowed_executable_path_count", "allowed_executable_paths_sha256",
        "argument_count", "arguments_sha256", "timeout_seconds",
        "control_valid_until_utc", "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_launch" -or
        $value.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger $value.sequence 0 0) -or
        -not (Test-CgceRecoveryInteger `
            $value.allowed_executable_path_count 1 4096) -or
        -not (Test-CgceRecoveryInteger `
            $value.argument_count 0 4096) -or
        -not (Test-CgceRecoveryInteger `
            $value.timeout_seconds 1 86400) -or
        -not (Test-CgceChecksum $value.executable_sha256) -or
        -not (Test-CgceChecksum `
            $value.allowed_executable_paths_sha256) -or
        -not (Test-CgceChecksum $value.arguments_sha256) -or
        $null -ne $value.previous_receipt_sha256) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch receipt fields"
    }
    $created = Assert-CgceStrictUtc `
        $value.created_at_utc `
        "CGCE-OPS-PROCESS-RECEIPT"
    $validUntil = Assert-CgceStrictUtc `
        $value.control_valid_until_utc `
        "CGCE-OPS-PROCESS-RECEIPT"
    if ($created.AddSeconds([int]$value.timeout_seconds) -gt $validUntil) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch exceeds control validity"
    }
    try {
        $executable = Get-CgceCanonicalForIdentity $value.executable_path
        $working = Get-CgceCanonicalForIdentity $value.working_directory
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch path"
    }
    if (-not (Test-CgceRecoveryPathEqual `
            (Split-Path -Parent $executable) `
            $working) -or
        @($CanonicalPaths | Where-Object {
                Test-CgceRecoveryPathEqual $_ $executable
            }).Count -ne 1 -or
        [int]$value.allowed_executable_path_count -ne
            $CanonicalPaths.Count -or
        $value.allowed_executable_paths_sha256 -cne
            (Get-CgceRecoveryFramedStringArraySha256 `
                "CGCE-PATHS-1" `
                $CanonicalPaths)) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch allowlist binding drift"
    }
    return $value
}

function Read-CgceRecoveryPidReceipt(
    [string]$Path,
    $State,
    [int]$ExpectedSequence,
    [string]$PreviousChecksum
) {
    try {
        $value = Read-CgceJsonObject $Path
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID receipt"
    }
    Assert-CgceRecoveryExactKeys $value @(
        "schema_version", "kind", "run_id", "sequence", "pid",
        "parent_pid", "executable_path", "creation_time_utc",
        "creation_time_filetime_utc", "observed_at_utc",
        "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_pid" -or
        $value.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger `
            $value.sequence $ExpectedSequence $ExpectedSequence) -or
        -not (Test-CgceRecoveryInteger `
            $value.pid 1 ([uint32]::MaxValue)) -or
        -not (Test-CgceRecoveryInteger `
            $value.parent_pid 0 ([uint32]::MaxValue)) -or
        -not (Test-CgceRecoveryInteger `
            $value.creation_time_filetime_utc 1 ([int64]::MaxValue)) -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID receipt chain"
    }
    $created = Assert-CgceStrictUtc `
        $value.creation_time_utc `
        "CGCE-OPS-PROCESS-RECEIPT"
    $observed = Assert-CgceStrictUtc `
        $value.observed_at_utc `
        "CGCE-OPS-PROCESS-RECEIPT"
    try {
        $null = Get-CgceCanonicalForIdentity $value.executable_path
        $expectedCreated = [DateTime]::FromFileTimeUtc(
            [int64]$value.creation_time_filetime_utc
        ).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID identity"
    }
    if ($value.creation_time_utc -cne $expectedCreated -or
        $observed -lt $created) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID timestamps"
    }
    return $value
}

function Read-CgceRecoveryManualReceipt(
    [string]$Path,
    $State,
    [string]$PreviousChecksum,
    [object[]]$PidReceipts
) {
    try {
        $value = Read-CgceJsonObject $Path
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid manual-recovery barrier"
    }
    Assert-CgceRecoveryExactKeys $value @(
        "schema_version", "kind", "run_id", "reason", "pid",
        "parent_pid", "observed_at_utc", "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne
            "cgce_windows_discovery_process_manual_recovery" -or
        $value.run_id -cne $State.run_id -or
        $value.reason -cne "IDENTITY_UNREADABLE" -or
        -not (Test-CgceRecoveryInteger `
            $value.pid 1 ([uint32]::MaxValue)) -or
        -not (Test-CgceRecoveryInteger `
            $value.parent_pid 0 ([uint32]::MaxValue)) -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid manual-recovery barrier"
    }
    $null = Assert-CgceStrictUtc `
        $value.observed_at_utc `
        "CGCE-OPS-PROCESS-RECEIPT"
    if ($PidReceipts.Count -eq 0) {
        if ([int64]$value.parent_pid -ne 0) {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid root recovery barrier"
        }
    } elseif (@($PidReceipts | Where-Object {
                [int64]$_.pid -eq [int64]$value.parent_pid
            }).Count -ne 1) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid descendant recovery barrier"
    }
    return $value
}

function Read-CgceRecoveryProcessReceiptChain(
    $State,
    [string[]]$CanonicalPaths
) {
    $root = $State.paths.process_receipts
    Assert-CgceRecoveryProcessReceiptDirectory $root
    $launchPath = Join-Path $root "000-launch.json"
    if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch receipt missing"
    }
    $launch = Read-CgceRecoveryLaunchReceipt `
        $launchPath `
        $State `
        $CanonicalPaths
    $launchExecutable = Get-CgceCanonicalForIdentity `
        $launch.executable_path
    $previous = Get-CgceSha256 $launchPath
    $receipts = New-Object 'Collections.Generic.List[object]'
    for ($sequence = 1; $sequence -le 998; $sequence += 1) {
        $path = Join-Path $root (
            $sequence.ToString("000") + "-pid.json"
        )
        if (-not (Test-Path -LiteralPath $path)) { break }
        $receipt = Read-CgceRecoveryPidReceipt `
            $path `
            $State `
            $sequence `
            $previous
        if (@($receipts.ToArray() | Where-Object {
                    [int64]$_.pid -eq [int64]$receipt.pid
                }).Count -ne 0) {
            throw "CGCE-OPS-PROCESS-RECEIPT duplicate PID identity"
        }
        if ($sequence -eq 1) {
            if ([int64]$receipt.parent_pid -ne 0 -or
                -not (Test-CgceRecoveryPathEqual `
                    $receipt.executable_path `
                    $launchExecutable)) {
                throw "CGCE-OPS-PROCESS-RECEIPT root PID launch binding drift"
            }
        } else {
            $parents = @($receipts.ToArray() | Where-Object {
                    [int64]$_.pid -eq [int64]$receipt.parent_pid
                })
            if ($parents.Count -ne 1 -or
                [int64]$receipt.creation_time_filetime_utc -lt
                    [int64]$parents[0].creation_time_filetime_utc) {
                throw "CGCE-OPS-PROCESS-RECEIPT descendant parent chain drift"
            }
        }
        $null = $receipts.Add($receipt)
        $previous = Get-CgceSha256 $path
    }
    $pidFiles = @(Get-ChildItem -LiteralPath $root -Filter "*-pid.json")
    if ($pidFiles.Count -ne $receipts.Count) {
        throw "CGCE-OPS-PROCESS-RECEIPT PID receipt sequence gap"
    }

    $manualPath = Join-Path $root "manual-recovery-required.json"
    if (Test-Path -LiteralPath $manualPath -PathType Leaf) {
        $null = Read-CgceRecoveryManualReceipt `
            $manualPath `
            $State `
            $previous `
            ([object[]]$receipts.ToArray())
        throw "CGCE-OPS-MANUAL-RECOVERY durable process identity barrier"
    }

    $resultPath = Join-Path $root "999-result.json"
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        try {
            $result = Read-CgceJsonObject $resultPath
        } catch {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid process result"
        }
        Assert-CgceRecoveryExactKeys $result @(
            "schema_version", "kind", "run_id", "sequence",
            "launch_receipt_sha256", "previous_receipt_sha256",
            "started_at_utc", "exit_at_utc", "exit_code",
            "observed_processes", "pid_receipts"
        ) "CGCE-OPS-PROCESS-RECEIPT"
        if ($result.schema_version -cne "1.0" -or
            $result.kind -cne "cgce_windows_discovery_process_result" -or
            $result.run_id -cne $State.run_id -or
            -not (Test-CgceRecoveryInteger $result.sequence 999 999) -or
            $result.launch_receipt_sha256 -cne
                (Get-CgceSha256 $launchPath) -or
            $result.previous_receipt_sha256 -cne $previous -or
            -not (Test-CgceRecoveryInteger `
                $result.exit_code ([int32]::MinValue) ([int32]::MaxValue)) -or
            $result.observed_processes -isnot [System.Array] -or
            $result.pid_receipts -isnot [System.Array] -or
            @($result.observed_processes).Count -ne $receipts.Count -or
            @($result.pid_receipts).Count -ne $receipts.Count) {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid process result fields"
        }
        $started = Assert-CgceStrictUtc `
            $result.started_at_utc `
            "CGCE-OPS-PROCESS-RECEIPT"
        $exited = Assert-CgceStrictUtc `
            $result.exit_at_utc `
            "CGCE-OPS-PROCESS-RECEIPT"
        if ($exited -lt $started) {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid process result timestamps"
        }
    }
    return [pscustomobject]@{
        launch = $launch
        pid_receipts = [object[]]$receipts.ToArray()
    }
}

function ConvertTo-CgceRecoveryCanonicalProcessFileTime(
    [int64]$FileTimeUtc
) {
    if ($FileTimeUtc -lt 1) {
        throw "CGCE-OPS-PROCESS-QUERY invalid process creation time"
    }
    $remainder = $FileTimeUtc % 10
    if ($remainder -ge 5) {
        if ($FileTimeUtc -gt ([int64]::MaxValue - (10 - $remainder))) {
            throw "CGCE-OPS-PROCESS-QUERY invalid process creation time"
        }
        return [int64]($FileTimeUtc + (10 - $remainder))
    }
    return [int64]($FileTimeUtc - $remainder)
}

function Get-CgceRecoveryProcessCreationFileTime($ProcessRecord) {
    if ($ProcessRecord.PSObject.Properties["CreationTimeFileTimeUtc"] -ne
        $null) {
        return ConvertTo-CgceRecoveryCanonicalProcessFileTime `
            ([int64]$ProcessRecord.CreationTimeFileTimeUtc)
    }
    if ($ProcessRecord.PSObject.Properties["CreationDate"] -eq $null -or
        $null -eq $ProcessRecord.CreationDate) {
        throw "CGCE-OPS-PROCESS-QUERY process creation time unavailable"
    }
    try {
        if ($ProcessRecord.CreationDate -is [DateTime]) {
            return ConvertTo-CgceRecoveryCanonicalProcessFileTime (
                ([DateTime]$ProcessRecord.CreationDate).
                    ToUniversalTime().
                    ToFileTimeUtc()
            )
        }
        return ConvertTo-CgceRecoveryCanonicalProcessFileTime (
            [Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$ProcessRecord.CreationDate
            ).ToUniversalTime().ToFileTimeUtc()
        )
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY invalid process creation time"
    }
}

function Assert-CgceRecoveryStateInactivity($State) {
    Assert-CgceRecoveryManualBarrier $State
    $paths = @(Get-CgceRecoveryExecutablePaths $State)
    $ports = @(Get-CgceRecoveryPorts $State)
    $chain = $null
    Assert-CgceRecoveryProcessReceiptDirectory `
        $State.paths.process_receipts
    if (@(Get-ChildItem `
            -LiteralPath $State.paths.process_receipts `
            -Force).Count -gt 0) {
        $chain = Read-CgceRecoveryProcessReceiptChain $State $paths
    }

    try {
        $null = Get-Command "Get-CimInstance" -ErrorAction Stop
        $processes = @(Get-CimInstance `
            -ClassName "Win32_Process" `
            -ErrorAction Stop)
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY process telemetry unavailable"
    }
    foreach ($process in $processes) {
        if ($null -eq $process) { continue }
        $observedProcessId = if (
            $process.PSObject.Properties["ProcessId"] -ne $null
        ) {
            [int64]$process.ProcessId
        } else {
            -1
        }
        $pathText = if (
            $process.PSObject.Properties["ExecutablePath"] -ne $null
        ) {
            [string]$process.ExecutablePath
        } else {
            ""
        }
        $processPath = $null
        if (-not [string]::IsNullOrWhiteSpace($pathText)) {
            try {
                $processPath = Get-CgceCanonicalForIdentity $pathText
            } catch {
                throw "CGCE-OPS-PROCESS-QUERY invalid process path"
            }
            foreach ($allowed in $paths) {
                if (Test-CgceRecoveryPathEqual $processPath $allowed) {
                    throw "CGCE-OPS-PROCESS-ACTIVE server process is active"
                }
            }
        }
        if ($null -ne $chain) {
            foreach ($receipt in @($chain.pid_receipts)) {
                if ([int64]$receipt.pid -eq $observedProcessId) {
                    if ([string]::IsNullOrWhiteSpace($pathText)) {
                        throw "CGCE-OPS-PROCESS-QUERY receipted PID identity unreadable"
                    }
                    $fileTime = Get-CgceRecoveryProcessCreationFileTime `
                        $process
                    if ((Test-CgceRecoveryPathEqual `
                            $processPath `
                            $receipt.executable_path) -and
                        [int64]$receipt.creation_time_filetime_utc -eq
                            $fileTime) {
                        throw "CGCE-OPS-PROCESS-ACTIVE durable PID identity is active"
                    }
                }
            }
        }
    }

    try {
        $null = Get-Command "Get-NetTCPConnection" -ErrorAction Stop
        $tcp = @(Get-NetTCPConnection -ErrorAction Stop)
        $null = Get-Command "Get-NetUDPEndpoint" -ErrorAction Stop
        $udp = @(Get-NetUDPEndpoint -ErrorAction Stop)
    } catch {
        throw "CGCE-OPS-PORT-QUERY endpoint telemetry unavailable"
    }
    foreach ($endpoint in $tcp) {
        if ($null -eq $endpoint -or
            $endpoint.PSObject.Properties["LocalPort"] -eq $null -or
            $endpoint.PSObject.Properties["State"] -eq $null) {
            throw "CGCE-OPS-PORT-QUERY incomplete TCP endpoint"
        }
        $endpointState = [string]$endpoint.State
        if ($ports -contains [int]$endpoint.LocalPort -and
            ($endpointState.Equals(
                    "Listen",
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $endpointState.Equals(
                    "Established",
                    [StringComparison]::OrdinalIgnoreCase
                ))) {
            throw "CGCE-OPS-PORT-ACTIVE configured TCP port active"
        }
    }
    foreach ($endpoint in $udp) {
        if ($null -eq $endpoint -or
            $endpoint.PSObject.Properties["LocalPort"] -eq $null) {
            throw "CGCE-OPS-PORT-QUERY incomplete UDP endpoint"
        }
        if ($ports -contains [int]$endpoint.LocalPort) {
            throw "CGCE-OPS-PORT-ACTIVE configured UDP port active"
        }
    }
}

function Assert-CgceRecoveryStatePath($State, [string]$StatePath) {
    $actual = Get-CgceCanonicalForIdentity $StatePath
    $recorded = Get-CgceCanonicalForIdentity $State.paths.state
    if (-not $actual.Equals($recorded, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CGCE-OPS-ID run-state path identity mismatch"
    }
}

function Read-CgceRecoveryState([string]$StatePath) {
    $state = Read-CgceJsonObject $StatePath
    Assert-CgceStateShape $state
    Assert-CgceCheckpointEvidence $state
    Assert-CgceRecoveryStatePath $state $StatePath
    $genesis = Read-CgceJsonObject $state.paths.genesis_state
    Assert-CgceGenesisState $genesis
    Assert-CgceStateIdentity $genesis $state
    return [pscustomobject]@{ state = $state; genesis = $genesis; checksum = (Get-CgceSha256 $StatePath) }
}

function Assert-CgceRecoveryArtifactState($Value) {
    Assert-CgceRecoveryExactKeys $Value @(
        "artifact_type", "present", "length", "sha256", "tree_sha256"
    )
    if ($Value.artifact_type -cne "DIRECTORY" -or
        $Value.present -isnot [bool] -or
        $null -ne $Value.length -or
        $null -ne $Value.sha256) {
        throw "CGCE-OPS-RECOVERY-INTENT invalid artifact state"
    }
    if ($Value.present) {
        if (-not (Test-CgceChecksum $Value.tree_sha256)) {
            throw "CGCE-OPS-RECOVERY-INTENT invalid artifact tree"
        }
    } elseif ($null -ne $Value.tree_sha256) {
        throw "CGCE-OPS-RECOVERY-INTENT absent artifact tree"
    }
}

function New-CgceRecoveryArtifactState([string]$TreeSha256, [bool]$Present) {
    if ($Present -and -not (Test-CgceChecksum $TreeSha256)) {
        throw "CGCE-OPS-RECOVERY-INTENT invalid artifact tree"
    }
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $Present
        length = $null
        sha256 = $null
        tree_sha256 = if ($Present) { $TreeSha256 } else { $null }
    }
}

function Assert-CgceRecoveryStep($Step) {
    Assert-CgceRecoveryExactKeys $Step @(
        "sequence", "step", "operation", "source_path", "destination_path",
        "before_state", "after_state"
    )
    foreach ($pair in @($Step.before_state, $Step.after_state)) {
        Assert-CgceRecoveryExactKeys $pair @("source", "destination")
        Assert-CgceRecoveryArtifactState $pair.source
        Assert-CgceRecoveryArtifactState $pair.destination
    }
}

function Test-CgceRecoveryNumericValue($Value) {
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
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

function Test-CgceRecoveryJsonEqual($Left, $Right) {
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
            if (-not (Test-CgceRecoveryJsonEqual `
                    @($Left)[$index] `
                    @($Right)[$index])) {
                return $false
            }
        }
        return $true
    }
    $leftNumber = Test-CgceRecoveryNumericValue $Left
    $rightNumber = Test-CgceRecoveryNumericValue $Right
    if ($leftNumber -or $rightNumber) {
        if (-not ($leftNumber -and $rightNumber)) { return $false }
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
    if ($leftNames.Count -ne $rightNames.Count) { return $false }
    for ($index = 0; $index -lt $leftNames.Count; $index += 1) {
        if ($leftNames[$index] -cne $rightNames[$index] -or
            -not (Test-CgceRecoveryJsonEqual `
                $Left.($leftNames[$index]) `
                $Right.($rightNames[$index]))) {
            return $false
        }
    }
    return $true
}

function Assert-CgceRecoveryErrorArray($Errors) {
    Assert-CgceDenseArray $Errors "CGCE-OPS-RECOVERY-INTENT"
    foreach ($record in @($Errors)) {
        Assert-CgceRecoveryExactKeys `
            $record `
            @("code", "at_utc")
        if ($record.code -isnot [string] -or
            $record.code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+\z') {
            throw "CGCE-OPS-RECOVERY-INTENT invalid source error"
        }
        $null = Assert-CgceStrictUtc `
            $record.at_utc `
            "CGCE-OPS-RECOVERY-INTENT"
    }
}

function Get-CgceRecoveryInventoryAuthority(
    $State,
    [string]$Name,
    [string]$Code = "CGCE-OPS-RECOVERY-INTENT"
) {
    if (@("original", "clone", "restored") -cnotcontains $Name) {
        throw "$Code unsupported inventory authority"
    }
    $path = $State.paths.($Name + "_inventory")
    try {
        $inventory = Read-CgceJsonObject $path
    } catch {
        throw "$Code invalid $Name inventory"
    }
    Assert-CgceExactKeys `
        $inventory `
        @("schema_version", "kind", "entries") `
        $Code
    if ($inventory.schema_version -cne "1.0" -or
        $inventory.kind -cne $Name -or
        $inventory.entries -isnot [System.Array]) {
        throw "$Code invalid $Name inventory"
    }
    $entries = [object[]]@($inventory.entries)
    $tree = Get-CgceInventoryTreeSha256 $entries
    $checksum = Get-CgceSha256 $path
    $recorded = $State.inventory_checksums.$Name
    if ($Name -ceq "original") {
        if (-not (Test-CgceChecksum $recorded) -or
            $checksum -cne $recorded) {
            throw "$Code original inventory checksum drift"
        }
    } elseif ($null -ne $recorded -and $checksum -cne $recorded) {
        throw "$Code $Name inventory checksum drift"
    }
    return [pscustomobject]@{
        path = $path
        checksum = $checksum
        tree_sha256 = $tree
        entries = $entries
    }
}

function Test-CgceRecoveryCaseAllowed(
    [string]$Phase,
    [string]$SelectedCase
) {
    $allowed = @{
        CREATED = @("UNCHANGED_ORIGINAL")
        BACKUP_VERIFIED = @(
            "UNCHANGED_ORIGINAL",
            "NO_ACTIVE_AND_INACTIVE_ORIGINAL"
        )
        ORIGINAL_DEACTIVATED = @(
            "NO_ACTIVE_AND_INACTIVE_ORIGINAL",
            "CLONE_AND_INACTIVE_ORIGINAL"
        )
        CLONE_ACTIVE = @("CLONE_AND_INACTIVE_ORIGINAL")
        PROBE_STAGED = @("CLONE_AND_INACTIVE_ORIGINAL")
        RUNNING = @("CLONE_AND_INACTIVE_ORIGINAL")
        CAPTURED = @("CLONE_AND_INACTIVE_ORIGINAL")
    }
    return $allowed.ContainsKey($Phase) -and
        $allowed[$Phase] -ccontains $SelectedCase
}

function Get-CgceRecoveryExpectedSteps(
    $State,
    $Intent,
    $OriginalAuthority,
    $CloneAuthority
) {
    $original = New-CgceRecoveryArtifactState `
        $OriginalAuthority.tree_sha256 `
        $true
    $absent = New-CgceRecoveryArtifactState "" $false
    $clone = if ($null -ne $CloneAuthority) {
        New-CgceRecoveryArtifactState $CloneAuthority.tree_sha256 $true
    } else {
        $null
    }
    $paths = $State.paths
    switch ($Intent.selected_case) {
        "UNCHANGED_ORIGINAL" {
            return [object[]]@(
                [pscustomobject][ordered]@{
                    sequence = 10
                    step = "QUARANTINE_CLONE"
                    operation = "VERIFY_RESTORED"
                    source_path = $paths.active_saved
                    destination_path = $paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $original; destination = $absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $original; destination = $absent
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "VERIFY_RESTORED"
                    source_path = $paths.inactive_original
                    destination_path = $paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $original
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $original
                    }
                }
            )
        }
        "NO_ACTIVE_AND_INACTIVE_ORIGINAL" {
            return [object[]]@(
                [pscustomobject][ordered]@{
                    sequence = 10
                    step = "QUARANTINE_CLONE"
                    operation = "VERIFY_ABSENT"
                    source_path = $paths.active_saved
                    destination_path = $paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $absent
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "MOVE_DIRECTORY"
                    source_path = $paths.inactive_original
                    destination_path = $paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $original; destination = $absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $original
                    }
                }
            )
        }
        "CLONE_AND_INACTIVE_ORIGINAL" {
            if ($null -eq $clone) {
                throw "CGCE-OPS-RECOVERY-INTENT clone authority missing"
            }
            return [object[]]@(
                [pscustomobject][ordered]@{
                    sequence = 10
                    step = "QUARANTINE_CLONE"
                    operation = "MOVE_DIRECTORY"
                    source_path = $paths.active_saved
                    destination_path = $paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $clone; destination = $absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $clone
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "MOVE_DIRECTORY"
                    source_path = $paths.inactive_original
                    destination_path = $paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $original; destination = $absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $absent; destination = $original
                    }
                }
            )
        }
        default {
            throw "CGCE-OPS-RECOVERY-INTENT invalid selected case"
        }
    }
}

function Assert-CgceRecoveryRestoringPreimage($State, $Intent) {
    $sourceRevision = [int64]$Intent.source_revision
    $currentRevision = [int64]$State.revision
    $legal = $false
    if ($currentRevision -eq $sourceRevision + 1 -and
        $State.outcome -ceq $Intent.source_outcome -and
        (Test-CgceRecoveryJsonEqual `
            $State.errors `
            $Intent.source_errors)) {
        $legal = $true
    } elseif ($currentRevision -eq $sourceRevision + 2 -and
        $State.outcome -ceq "BLOCKED") {
        $sourceErrors = @($Intent.source_errors)
        $currentErrors = @($State.errors)
        if ($currentErrors.Count -eq $sourceErrors.Count + 1) {
            $legal = $true
            for ($index = 0; $index -lt $sourceErrors.Count; $index += 1) {
                if (-not (Test-CgceRecoveryJsonEqual `
                        $sourceErrors[$index] `
                        $currentErrors[$index])) {
                    $legal = $false
                }
            }
            if ($legal) {
                Assert-CgceRecoveryExactKeys `
                    $currentErrors[-1] `
                    @("code", "at_utc")
                if ($currentErrors[-1].code -cnotmatch
                        '^CGCE-OPS-[A-Z0-9-]+\z') {
                    $legal = $false
                } else {
                    $null = Assert-CgceStrictUtc `
                        $currentErrors[-1].at_utc `
                        "CGCE-OPS-RECOVERY-INTENT"
                }
            }
        }
    }
    if (-not $legal) {
        throw "CGCE-OPS-RECOVERY-INTENT RESTORING state delta drift"
    }
    $preimage = New-Object PSObject
    foreach ($property in @($State.PSObject.Properties)) {
        $preimage | Add-Member `
            -MemberType NoteProperty `
            -Name $property.Name `
            -Value $property.Value
    }
    $preimage.phase = $Intent.source_phase
    $preimage.outcome = $Intent.source_outcome
    $preimage.revision = [int64]$Intent.source_revision
    $preimage.updated_at_utc = $Intent.source_updated_at_utc
    $preimage.errors = [object[]]@($Intent.source_errors)
    $encodings = @(
        (ConvertTo-CgceJsonText $preimage),
        ($preimage | ConvertTo-Json -Depth 12 -Compress)
    )
    $matched = $false
    foreach ($text in $encodings) {
        if ((Get-CgceTextSha256 $text) -ceq
            $Intent.source_state_sha256) {
            $matched = $true
        }
    }
    if (-not $matched) {
        throw "CGCE-OPS-RECOVERY-INTENT source preimage checksum drift"
    }
}

function Assert-CgceRecoveryIntent(
    $State,
    $Genesis,
    [string]$StateChecksum,
    [string]$RecoveryIntentPath,
    [switch]$AllowRestoring
) {
    $expectedIntentPath = Join-Path `
        $State.paths.restore_receipts `
        "000-restore-intent.json"
    if ((Split-Path -Leaf $RecoveryIntentPath) -cne
            "000-restore-intent.json" -or
        -not (Test-CgceRecoveryPathEqual `
            $RecoveryIntentPath `
            $expectedIntentPath)) {
        throw "CGCE-OPS-RECOVERY-INTENT intent path authority drift"
    }
    try {
        $intent = Read-CgceJsonObject $RecoveryIntentPath
    } catch {
        throw "CGCE-OPS-RECOVERY-INTENT invalid recovery intent"
    }
    Assert-CgceRecoveryExactKeys $intent @(
        "schema_version", "kind", "run_id", "sequence", "created_at_utc",
        "source_state_sha256", "source_phase", "source_outcome",
        "source_revision", "source_updated_at_utc", "source_errors",
        "genesis_state_sha256", "original_inventory_sha256",
        "original_tree_sha256", "selected_case", "paths", "steps"
    )
    if ($intent.schema_version -cne "1.0" -or
        $intent.kind -cne "cgce_windows_discovery_restore_intent" -or
        $intent.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger $intent.sequence 0 0) -or
        -not (Test-CgceRecoveryInteger `
            $intent.source_revision 0 ([int64]::MaxValue)) -or
        -not (Test-CgceChecksum $intent.source_state_sha256) -or
        -not (Test-CgceChecksum $intent.genesis_state_sha256) -or
        -not (Test-CgceChecksum $intent.original_inventory_sha256) -or
        -not (Test-CgceChecksum $intent.original_tree_sha256) -or
        @("ACTIVE", "BLOCKED") -cnotcontains $intent.source_outcome -or
        -not (Test-CgceRecoveryCaseAllowed `
            $intent.source_phase `
            $intent.selected_case)) {
        throw "CGCE-OPS-RECOVERY-INTENT invalid recovery intent"
    }
    $null = Assert-CgceStrictUtc `
        $intent.created_at_utc `
        "CGCE-OPS-RECOVERY-INTENT"
    $null = Assert-CgceStrictUtc `
        $intent.source_updated_at_utc `
        "CGCE-OPS-RECOVERY-INTENT"
    Assert-CgceRecoveryErrorArray $intent.source_errors

    Assert-CgceRecoveryExactKeys $intent.paths @(
        "active_saved", "inactive_original", "quarantined_clone",
        "original_inventory", "restored_inventory", "restore_receipts",
        "probe_restore_final_receipt"
    )
    foreach ($name in @(
            "active_saved", "inactive_original", "quarantined_clone",
            "original_inventory", "restored_inventory", "restore_receipts"
        )) {
        if ($intent.paths.$name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($intent.paths.$name) -or
            -not (Test-CgceRecoveryPathEqual `
                $intent.paths.$name `
                $State.paths.$name)) {
            throw "CGCE-OPS-RECOVERY-INTENT path authority drift"
        }
    }
    $expectedProbeFinal = Join-Path `
        (Join-Path $State.paths.probe_receipts "restore") `
        "999-probe-restore-final.json"
    if ($intent.paths.probe_restore_final_receipt -isnot [string] -or
        -not (Test-CgceRecoveryPathEqual `
            $intent.paths.probe_restore_final_receipt `
            $expectedProbeFinal)) {
        throw "CGCE-OPS-RECOVERY-INTENT probe final path drift"
    }

    $original = Get-CgceRecoveryInventoryAuthority `
        $State `
        "original"
    if ((Get-CgceSha256 $State.paths.genesis_state) -cne
            $intent.genesis_state_sha256 -or
        (Get-CgceSha256 $State.paths.genesis_state) -cne
            (Get-CgceSha256 $Genesis.paths.genesis_state) -or
        $original.checksum -cne
            $intent.original_inventory_sha256 -or
        $original.tree_sha256 -cne
            $intent.original_tree_sha256) {
        throw "CGCE-OPS-RECOVERY-INTENT immutable authority drift"
    }
    $clone = $null
    if ($intent.selected_case -ceq
        "CLONE_AND_INACTIVE_ORIGINAL") {
        $clone = Get-CgceRecoveryInventoryAuthority `
            $State `
            "clone"
    }
    if ($intent.steps -isnot [System.Array] -or
        @($intent.steps).Count -ne 2) {
        throw "CGCE-OPS-RECOVERY-INTENT fixed steps required"
    }
    foreach ($step in @($intent.steps)) {
        Assert-CgceRecoveryStep $step
    }
    $expected = @(Get-CgceRecoveryExpectedSteps `
        $State `
        $intent `
        $original `
        $clone)
    for ($index = 0; $index -lt 2; $index += 1) {
        if (-not (Test-CgceRecoveryJsonEqual `
                $expected[$index] `
                @($intent.steps)[$index])) {
            throw "CGCE-OPS-RECOVERY-INTENT step authority drift"
        }
    }

    if ($State.phase -ceq $intent.source_phase) {
        if ($StateChecksum -cne $intent.source_state_sha256 -or
            $State.outcome -cne $intent.source_outcome -or
            [int64]$State.revision -ne
                [int64]$intent.source_revision -or
            $State.updated_at_utc -cne
                $intent.source_updated_at_utc -or
            -not (Test-CgceRecoveryJsonEqual `
                $State.errors `
                $intent.source_errors) -or
            -not (Test-CgceRecoverySourceEvidence `
                $State `
                $intent.source_phase) -or
            $null -ne $State.inventory_checksums.restored) {
            throw "CGCE-OPS-RECOVERY-INTENT source preimage drift"
        }
    } elseif ($AllowRestoring -and $State.phase -ceq "RESTORING") {
        Assert-CgceRecoveryRestoringPreimage $State $intent
    } else {
        throw "CGCE-OPS-RECOVERY-INTENT state/intent phase drift"
    }
    return $intent
}

function Write-CgceRecoveryStateCas(
    $Current,
    [string]$StatePath,
    [string]$ExpectedChecksum,
    [string]$ExpectedPhase
) {
    $next = $Current
    $next.revision = [int64]$Current.revision + 1
    $next.updated_at_utc = Get-CgceRecoveryUtcNow
    Assert-CgceStateShape $next
    Assert-CgceCheckpointEvidence $next
    $text = ConvertTo-CgceJsonText $next
    $checksum = Get-CgceTextSha256 $text
    Assert-CgceRecoveryStateInactivity $next
    Replace-CgceRunStateJson $next $StatePath $ExpectedChecksum
    Confirm-CgceRunStateReadBack `
        $StatePath `
        $checksum `
        ([int64]$next.revision) `
        $ExpectedPhase
    $readBack = Read-CgceRunStateAfterReplace $StatePath
    if (-not (Test-CgceRecoveryJsonEqual $next $readBack)) {
        throw "CGCE-OPS-CHECKSUM recovery state semantic read-back drift"
    }
}

function Write-CgceRecoveryRunState(
    [string]$StatePath,
    [string]$RecoveryIntentPath
) {
    $fresh = Read-CgceRecoveryState $StatePath
    Assert-CgceRecoveryManualBarrier $fresh.state
    $null = Assert-CgceRecoveryIntent `
        $fresh.state `
        $fresh.genesis `
        $fresh.checksum `
        $RecoveryIntentPath
    $receiptRoot = $fresh.state.paths.restore_receipts
    if (-not (Test-CgceRecoveryPathEqual `
            $receiptRoot `
            (Split-Path -Parent $RecoveryIntentPath)) -or
        @(Get-ChildItem -LiteralPath $receiptRoot -Force).Count -ne 1) {
        throw "CGCE-OPS-RECOVERY-INTENT initial receipt authority drift"
    }
    Assert-CgceRunMarker $fresh.state
    $fresh.state.phase = "RESTORING"
    Write-CgceRecoveryStateCas `
        $fresh.state `
        $StatePath `
        $fresh.checksum `
        "RESTORING"
}

function Block-CgceRecoveryRunState(
    [string]$StatePath,
    [string]$RecoveryIntentPath,
    [string]$Code
) {
    if ($Code -isnot [string] -or
        $Code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+\z') {
        throw "CGCE-OPS-BLOCKED invalid stable error code"
    }
    $fresh = Read-CgceRecoveryState $StatePath
    Assert-CgceRecoveryManualBarrier $fresh.state
    $intent = Assert-CgceRecoveryIntent `
        $fresh.state `
        $fresh.genesis `
        $fresh.checksum `
        $RecoveryIntentPath `
        -AllowRestoring
    if ($fresh.state.phase -cne "RESTORING" -or
        [int64]$fresh.state.revision -ne
            ([int64]$intent.source_revision + 1) -or
        $fresh.state.outcome -cne $intent.source_outcome -or
        -not (Test-CgceRecoveryJsonEqual `
            $fresh.state.errors `
            $intent.source_errors)) {
        throw "CGCE-OPS-PHASE recovery blocker preimage drift"
    }
    Assert-CgceRunMarker $fresh.state
    $errors = New-Object 'Collections.Generic.List[object]'
    foreach ($errorRecord in @($fresh.state.errors)) {
        $null = $errors.Add($errorRecord)
    }
    $null = $errors.Add([pscustomobject][ordered]@{
        code = $Code
        at_utc = (Get-CgceRecoveryUtcNow)
    })
    $fresh.state.errors = [object[]]$errors.ToArray()
    $fresh.state.outcome = "BLOCKED"
    Write-CgceRecoveryStateCas `
        $fresh.state `
        $StatePath `
        $fresh.checksum `
        "RESTORING"
}

function Assert-CgceRecoveryNoReparseInPath(
    [string]$Path,
    [string]$Code
) {
    try {
        $canonical = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($canonical)
    } catch {
        throw "$Code invalid path"
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Code invalid path root"
    }
    $current = $root
    $relative = $canonical.Substring($root.Length)
    $components = @($relative.Split(
        [char[]]@('\', '/'),
        [StringSplitOptions]::RemoveEmptyEntries
    ))
    foreach ($component in $components) {
        $current = [IO.Path]::Combine($current, $component)
        if (-not (Test-Path -LiteralPath $current)) { break }
        try {
            $item = Get-Item -LiteralPath $current -Force
        } catch {
            throw "$Code cannot inspect path"
        }
        if (($item.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Code reparse point found"
        }
    }
}

function Get-CgceRecoveryDirectoryEntries(
    [string]$Root,
    [string]$Code
) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$Code directory is missing"
    }
    Assert-CgceRecoveryNoReparseInPath $Root $Code
    $records = New-Object 'Collections.Generic.List[object]'
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $item = Get-Item -LiteralPath $directory -Force
            $children = @(Get-ChildItem -LiteralPath $directory -Force)
        } catch {
            throw "$Code cannot enumerate directory"
        }
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Code invalid directory tree"
        }
        foreach ($child in $children) {
            if (($child.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Code reparse point found"
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
                continue
            }
            $relative = $child.FullName.Substring(
                [IO.Path]::GetFullPath($Root).TrimEnd('\', '/').Length
            ).TrimStart('\', '/').Replace('\', '/')
            $null = $records.Add([pscustomobject][ordered]@{
                relative_path = $relative
                length = [int64]$child.Length
                sha256 = (Get-CgceSha256 $child.FullName)
            })
        }
    }
    $sorted = [object[]]$records.ToArray()
    for ($index = 1; $index -lt $sorted.Count; $index += 1) {
        $record = $sorted[$index]
        $position = $index - 1
        while ($position -ge 0 -and
            [StringComparer]::Ordinal.Compare(
                [string]$sorted[$position].relative_path,
                [string]$record.relative_path
            ) -gt 0) {
            $sorted[$position + 1] = $sorted[$position]
            $position -= 1
        }
        $sorted[$position + 1] = $record
    }
    return [object[]]$sorted
}

function New-CgceRecoveryGenericArtifactState(
    [string]$Path,
    [ValidateSet("FILE", "DIRECTORY")]
    [string]$Type,
    [string]$Code
) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{
            artifact_type = $Type
            present = $false
            length = $null
            sha256 = $null
            tree_sha256 = $null
        }
    }
    Assert-CgceRecoveryNoReparseInPath $Path $Code
    if ($Type -ceq "FILE") {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "$Code artifact type drift"
        }
        $item = Get-Item -LiteralPath $Path -Force
        return [pscustomobject][ordered]@{
            artifact_type = "FILE"
            present = $true
            length = [int64]$item.Length
            sha256 = (Get-CgceSha256 $Path)
            tree_sha256 = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Code artifact type drift"
    }
    $entries = @(Get-CgceRecoveryDirectoryEntries $Path $Code)
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $true
        length = $null
        sha256 = $null
        tree_sha256 = (Get-CgceInventoryTreeSha256 $entries)
    }
}

function Assert-CgceRecoveryGenericArtifactState(
    $Value,
    [ValidateSet("FILE", "DIRECTORY")]
    [string]$Type,
    [string]$Code
) {
    Assert-CgceExactKeys $Value @(
        "artifact_type", "present", "length", "sha256", "tree_sha256"
    ) $Code
    if ($Value.artifact_type -cne $Type -or
        $Value.present -isnot [bool]) {
        throw "$Code invalid artifact state"
    }
    if (-not $Value.present) {
        if ($null -ne $Value.length -or
            $null -ne $Value.sha256 -or
            $null -ne $Value.tree_sha256) {
            throw "$Code invalid absent artifact state"
        }
        return
    }
    if ($Type -ceq "FILE") {
        if (-not (Test-CgceRecoveryInteger `
                $Value.length 0 ([int64]::MaxValue)) -or
            -not (Test-CgceChecksum $Value.sha256) -or
            $null -ne $Value.tree_sha256) {
            throw "$Code invalid file artifact state"
        }
    } elseif ($null -ne $Value.length -or
        $null -ne $Value.sha256 -or
        -not (Test-CgceChecksum $Value.tree_sha256)) {
        throw "$Code invalid directory artifact state"
    }
}

function Assert-CgceRecoveryNoProbeResidue($State) {
    foreach ($path in @(
            $State.paths.probe_staged,
            $State.paths.probe_quarantine,
            $State.paths.mods_original,
            $State.paths.mods_test,
            $State.paths.object_dump_original,
            $State.paths.object_dump_quarantine,
            $State.paths.cxx_header_dump_original,
            $State.paths.cxx_header_dump_quarantine,
            $State.paths.ue4ss_log_original,
            $State.paths.ue4ss_log_quarantine
        )) {
        if (Test-Path -LiteralPath $path) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe residue without intent"
        }
    }
    if (Test-Path -LiteralPath $State.paths.probe_receipts `
        -PathType Container) {
        if (@(Get-ChildItem `
                -LiteralPath $State.paths.probe_receipts `
                -Force).Count -gt 0) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe journal without intent"
        }
    }
    $before = Join-Path $State.paths.run_directory "before"
    if (Test-Path -LiteralPath $before -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $before -Force).Count -gt 0) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe snapshots without intent"
        }
    }
    if (Test-Path -LiteralPath $State.paths.mods_txt -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines(
                $State.paths.mods_txt
            )) {
            if ($line -match
                '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?\z') {
                throw "CGCE-OPS-MANUAL-RECOVERY probe enablement without intent"
            }
        }
    }
}

function Assert-CgceRecoveryProbePathObject(
    $Expected,
    $Actual
) {
    $expectedKeys = @(
        $Expected.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    Assert-CgceExactKeys `
        $Actual `
        ([string[]]$expectedKeys) `
        "CGCE-OPS-PROBE-RECEIPT"
    foreach ($name in $expectedKeys) {
        if ($Expected.$name -isnot [string] -or
            $Actual.$name -isnot [string] -or
            -not (Test-CgceRecoveryPathEqual `
                $Expected.$name `
                $Actual.$name)) {
            throw "CGCE-OPS-PROBE-RECEIPT probe path binding drift"
        }
    }
}

function Get-CgceRecoveryProbeOperationSpecs($State) {
    return [object[]]@(
        [pscustomobject]@{
            sequence = 10; leaf = "010-quarantine-probe.json"
            step = "QUARANTINE_PROBE"; type = "DIRECTORY"
            source = $State.paths.probe_staged
            destination = $State.paths.probe_quarantine
        },
        [pscustomobject]@{
            sequence = 20; leaf = "020-quarantine-test-mods.json"
            step = "QUARANTINE_TEST_MODS"; type = "FILE"
            source = $State.paths.mods_txt
            destination = $State.paths.mods_test
        },
        [pscustomobject]@{
            sequence = 30; leaf = "030-restore-mods.json"
            step = "RESTORE_MODS"; type = "FILE"
            source = $State.paths.mods_original
            destination = $State.paths.mods_txt
        },
        [pscustomobject]@{
            sequence = 40; leaf = "040-quarantine-object-dump.json"
            step = "QUARANTINE_OBJECT_DUMP"; type = "FILE"
            source = $State.paths.object_dump
            destination = $State.paths.object_dump_quarantine
        },
        [pscustomobject]@{
            sequence = 50; leaf = "050-restore-object-dump.json"
            step = "RESTORE_OBJECT_DUMP"; type = "FILE"
            source = $State.paths.object_dump_original
            destination = $State.paths.object_dump
        },
        [pscustomobject]@{
            sequence = 60; leaf = "060-quarantine-cxx-header-dump.json"
            step = "QUARANTINE_CXX_HEADER_DUMP"; type = "DIRECTORY"
            source = $State.paths.cxx_header_dump
            destination = $State.paths.cxx_header_dump_quarantine
        },
        [pscustomobject]@{
            sequence = 70; leaf = "070-restore-cxx-header-dump.json"
            step = "RESTORE_CXX_HEADER_DUMP"; type = "DIRECTORY"
            source = $State.paths.cxx_header_dump_original
            destination = $State.paths.cxx_header_dump
        },
        [pscustomobject]@{
            sequence = 80; leaf = "080-quarantine-ue4ss-log.json"
            step = "QUARANTINE_UE4SS_LOG"; type = "FILE"
            source = $State.paths.ue4ss_log
            destination = $State.paths.ue4ss_log_quarantine
        },
        [pscustomobject]@{
            sequence = 90; leaf = "090-restore-ue4ss-log.json"
            step = "RESTORE_UE4SS_LOG"; type = "FILE"
            source = $State.paths.ue4ss_log_original
            destination = $State.paths.ue4ss_log
        }
    )
}

function Assert-CgceRecoveryProbeTerminalArtifact(
    [string]$Path,
    [string]$Type,
    $Expected
) {
    $actual = New-CgceRecoveryGenericArtifactState `
        $Path `
        $Type `
        "CGCE-OPS-MANUAL-RECOVERY"
    if (-not (Test-CgceRecoveryJsonEqual $actual $Expected)) {
        throw "CGCE-OPS-MANUAL-RECOVERY probe terminal state drift"
    }
}

function Assert-CgceRecoveryProbeRestored(
    $State,
    $FinalBinding
) {
    if ($null -eq $State.probe_receipt_checksum) {
        if ($null -ne $FinalBinding) {
            throw "CGCE-OPS-RESTORE-RECEIPT unexpected probe final binding"
        }
        Assert-CgceRecoveryNoProbeResidue $State
        return
    }
    if ($null -eq $FinalBinding) {
        throw "CGCE-OPS-RESTORE-RECEIPT missing probe final binding"
    }
    Assert-CgceExactKeys `
        $FinalBinding `
        @("path", "sha256") `
        "CGCE-OPS-RESTORE-RECEIPT"
    $restoreRoot = Join-Path $State.paths.probe_receipts "restore"
    $finalPath = Join-Path `
        $restoreRoot `
        "999-probe-restore-final.json"
    if (-not (Test-CgceRecoveryPathEqual `
            $FinalBinding.path `
            $finalPath) -or
        -not (Test-CgceChecksum $FinalBinding.sha256) -or
        (Get-CgceSha256 $finalPath) -cne $FinalBinding.sha256) {
        throw "CGCE-OPS-RESTORE-RECEIPT probe final binding drift"
    }
    if (-not (Test-Path -LiteralPath $State.paths.probe_intent `
            -PathType Leaf) -or
        -not (Test-Path -LiteralPath $State.paths.probe_receipt `
            -PathType Leaf) -or
        (Get-CgceSha256 $State.paths.probe_receipt) -cne
            $State.probe_receipt_checksum) {
        throw "CGCE-OPS-PROBE-RECEIPT probe stage authority drift"
    }
    try {
        $stageIntent = Read-CgceJsonObject $State.paths.probe_intent
    } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid probe intent"
    }
    Assert-CgceExactKeys $stageIntent @(
        "schema_version", "kind", "run_id", "created_at_utc",
        "run_directory", "ue4ss_root", "paths", "snapshots"
    ) "CGCE-OPS-PROBE-RECEIPT"
    if ($stageIntent.schema_version -cne "1.0" -or
        $stageIntent.kind -cne
            "cgce_windows_discovery_probe_intent" -or
        $stageIntent.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryPathEqual `
            $stageIntent.run_directory `
            $State.paths.run_directory) -or
        -not (Test-CgceRecoveryPathEqual `
            $stageIntent.ue4ss_root `
            $State.paths.ue4ss_root)) {
        throw "CGCE-OPS-PROBE-RECEIPT probe intent identity drift"
    }
    $null = Assert-CgceStrictUtc `
        $stageIntent.created_at_utc `
        "CGCE-OPS-PROBE-RECEIPT"

    $restoreIntentPath = Join-Path `
        $restoreRoot `
        "000-probe-restore-intent.json"
    try {
        $restoreIntent = Read-CgceJsonObject $restoreIntentPath
    } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid probe restore intent"
    }
    Assert-CgceExactKeys $restoreIntent @(
        "schema_version", "kind", "run_id", "sequence",
        "created_at_utc", "stage_intent_sha256", "stage_final_sha256",
        "stage_chain_last_sequence", "stage_chain_last_sha256",
        "paths", "plans"
    ) "CGCE-OPS-PROBE-RECEIPT"
    if ($restoreIntent.schema_version -cne "1.0" -or
        $restoreIntent.kind -cne
            "cgce_windows_discovery_probe_restore_intent" -or
        $restoreIntent.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger `
            $restoreIntent.sequence 0 0) -or
        -not (Test-CgceChecksum `
            $restoreIntent.stage_intent_sha256) -or
        $restoreIntent.stage_intent_sha256 -cne
            (Get-CgceSha256 $State.paths.probe_intent) -or
        $restoreIntent.stage_final_sha256 -cne
            $State.probe_receipt_checksum -or
        -not (Test-CgceRecoveryInteger `
            $restoreIntent.stage_chain_last_sequence 0 60) -or
        -not (Test-CgceChecksum `
            $restoreIntent.stage_chain_last_sha256) -or
        $restoreIntent.plans -isnot [System.Array] -or
        @($restoreIntent.plans).Count -ne 5) {
        throw "CGCE-OPS-PROBE-RECEIPT probe restore intent drift"
    }
    $null = Assert-CgceStrictUtc `
        $restoreIntent.created_at_utc `
        "CGCE-OPS-PROBE-RECEIPT"
    Assert-CgceRecoveryProbePathObject `
        $stageIntent.paths `
        $restoreIntent.paths

    $specs = @(Get-CgceRecoveryProbeOperationSpecs $State)
    $allowed = @(
        "000-probe-restore-intent.json",
        "999-probe-restore-final.json"
    ) + @($specs | ForEach-Object { $_.leaf })
    $children = @(Get-ChildItem -LiteralPath $restoreRoot -Force)
    if ($children.Count -ne 11) {
        throw "CGCE-OPS-PROBE-RECEIPT full probe restore journal required"
    }
    foreach ($child in $children) {
        if ($child.PSIsContainer -or
            $allowed -cnotcontains $child.Name) {
            throw "CGCE-OPS-PROBE-RECEIPT foreign probe restore receipt"
        }
    }

    $previous = Get-CgceSha256 $restoreIntentPath
    $bindings = New-Object 'Collections.Generic.List[object]'
    $receipts = @{}
    foreach ($spec in $specs) {
        $path = Join-Path $restoreRoot $spec.leaf
        try {
            $receipt = Read-CgceJsonObject $path
        } catch {
            throw "CGCE-OPS-PROBE-RECEIPT invalid probe restore operation"
        }
        Assert-CgceExactKeys $receipt @(
            "schema_version", "kind", "run_id", "sequence", "step",
            "operation", "source_path", "destination_path",
            "before_state", "after_state", "previous_receipt_sha256",
            "completed_at_utc"
        ) "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceRecoveryExactKeys `
            $receipt.before_state `
            @("source", "destination") `
            "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceRecoveryExactKeys `
            $receipt.after_state `
            @("source", "destination") `
            "CGCE-OPS-PROBE-RECEIPT"
        foreach ($artifact in @(
                $receipt.before_state.source,
                $receipt.before_state.destination,
                $receipt.after_state.source,
                $receipt.after_state.destination
            )) {
            Assert-CgceRecoveryGenericArtifactState `
                $artifact `
                $spec.type `
                "CGCE-OPS-PROBE-RECEIPT"
        }
        if ($receipt.schema_version -cne "1.0" -or
            $receipt.kind -cne
                "cgce_windows_discovery_probe_restore_operation" -or
            $receipt.run_id -cne $State.run_id -or
            -not (Test-CgceRecoveryInteger `
                $receipt.sequence `
                $spec.sequence `
                $spec.sequence) -or
            $receipt.step -cne $spec.step -or
            @(
                "MOVE_FILE", "MOVE_DIRECTORY", "VERIFY_ABSENT",
                "VERIFY_RESTORED"
            ) -cnotcontains $receipt.operation -or
            -not (Test-CgceRecoveryPathEqual `
                $receipt.source_path `
                $spec.source) -or
            -not (Test-CgceRecoveryPathEqual `
                $receipt.destination_path `
                $spec.destination) -or
            $receipt.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT probe restore operation drift"
        }
        $null = Assert-CgceStrictUtc `
            $receipt.completed_at_utc `
            "CGCE-OPS-PROBE-RECEIPT"
        $previous = Get-CgceSha256 $path
        $binding = [pscustomobject][ordered]@{
            sequence = [int]$spec.sequence
            path = $path
            sha256 = $previous
        }
        $null = $bindings.Add($binding)
        $receipts[[string]$spec.sequence] = $receipt
    }

    try {
        $final = Read-CgceJsonObject $finalPath
    } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid probe restore final"
    }
    Assert-CgceExactKeys $final @(
        "schema_version", "kind", "run_id", "sequence",
        "restore_intent_sha256", "previous_receipt_sha256", "paths",
        "operation_receipts", "restored_states", "completed_at_utc"
    ) "CGCE-OPS-PROBE-RECEIPT"
    if ($final.schema_version -cne "1.0" -or
        $final.kind -cne
            "cgce_windows_discovery_probe_restore_final" -or
        $final.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger $final.sequence 999 999) -or
        $final.restore_intent_sha256 -cne
            (Get-CgceSha256 $restoreIntentPath) -or
        $final.previous_receipt_sha256 -cne $previous -or
        $final.operation_receipts -isnot [System.Array] -or
        @($final.operation_receipts).Count -ne 9 -or
        $final.restored_states -isnot [System.Array] -or
        @($final.restored_states).Count -ne 5) {
        throw "CGCE-OPS-PROBE-RECEIPT probe restore final drift"
    }
    $null = Assert-CgceStrictUtc `
        $final.completed_at_utc `
        "CGCE-OPS-PROBE-RECEIPT"
    Assert-CgceRecoveryProbePathObject `
        $restoreIntent.paths `
        $final.paths
    for ($index = 0; $index -lt 9; $index += 1) {
        $actual = @($final.operation_receipts)[$index]
        $expected = $bindings[$index]
        Assert-CgceExactKeys `
            $actual `
            @("sequence", "path", "sha256") `
            "CGCE-OPS-PROBE-RECEIPT"
        if (-not (Test-CgceRecoveryInteger `
                $actual.sequence `
                $expected.sequence `
                $expected.sequence) -or
            -not (Test-CgceRecoveryPathEqual `
                $actual.path `
                $expected.path) -or
            $actual.sha256 -cne $expected.sha256) {
            throw "CGCE-OPS-PROBE-RECEIPT probe final binding drift"
        }
    }

    $terminal = @(
        [pscustomobject]@{
            name = "PROBE"; path = $State.paths.probe_staged
            type = "DIRECTORY"
        },
        [pscustomobject]@{
            name = "MODS_TXT"; path = $State.paths.mods_txt
            type = "FILE"
        },
        [pscustomobject]@{
            name = "OBJECT_DUMP"; path = $State.paths.object_dump
            type = "FILE"
        },
        [pscustomobject]@{
            name = "CXX_HEADER_DUMP"; path = $State.paths.cxx_header_dump
            type = "DIRECTORY"
        },
        [pscustomobject]@{
            name = "UE4SS_LOG"; path = $State.paths.ue4ss_log
            type = "FILE"
        }
    )
    for ($index = 0; $index -lt 5; $index += 1) {
        $record = @($final.restored_states)[$index]
        $expected = $terminal[$index]
        Assert-CgceExactKeys `
            $record `
            @("artifact_name", "state") `
            "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceRecoveryGenericArtifactState `
            $record.state `
            $expected.type `
            "CGCE-OPS-PROBE-RECEIPT"
        if ($record.artifact_name -cne $expected.name) {
            throw "CGCE-OPS-PROBE-RECEIPT probe terminal binding drift"
        }
        Assert-CgceRecoveryProbeTerminalArtifact `
            $expected.path `
            $expected.type `
            $record.state
    }

    $terminalReceiptChecks = @(
        @("10", "source", $State.paths.probe_staged, "DIRECTORY"),
        @("10", "destination", $State.paths.probe_quarantine, "DIRECTORY"),
        @("20", "destination", $State.paths.mods_test, "FILE"),
        @("30", "source", $State.paths.mods_original, "FILE"),
        @("30", "destination", $State.paths.mods_txt, "FILE"),
        @("40", "destination", $State.paths.object_dump_quarantine, "FILE"),
        @("50", "source", $State.paths.object_dump_original, "FILE"),
        @("50", "destination", $State.paths.object_dump, "FILE"),
        @("60", "destination", $State.paths.cxx_header_dump_quarantine, "DIRECTORY"),
        @("70", "source", $State.paths.cxx_header_dump_original, "DIRECTORY"),
        @("70", "destination", $State.paths.cxx_header_dump, "DIRECTORY"),
        @("80", "destination", $State.paths.ue4ss_log_quarantine, "FILE"),
        @("90", "source", $State.paths.ue4ss_log_original, "FILE"),
        @("90", "destination", $State.paths.ue4ss_log, "FILE")
    )
    foreach ($check in $terminalReceiptChecks) {
        $receipt = $receipts[[string]$check[0]]
        $side = [string]$check[1]
        $expectedState = $receipt.after_state.$side
        Assert-CgceRecoveryProbeTerminalArtifact `
            ([string]$check[2]) `
            ([string]$check[3]) `
            $expectedState
    }
}

function Assert-CgceRecoveryFinalJournal(
    $State,
    $Intent,
    [string]$RecoveryIntentPath
) {
    $root = $State.paths.restore_receipts
    $allowed = @(
        "000-restore-intent.json",
        "010-quarantine-clone.json",
        "020-restore-original.json",
        "999-restore-final.json"
    )
    $children = @(Get-ChildItem -LiteralPath $root -Force)
    if ($children.Count -ne 4) {
        throw "CGCE-OPS-RESTORE-RECEIPT exact recovery receipt set required"
    }
    foreach ($child in $children) {
        if ($child.PSIsContainer -or
            $allowed -cnotcontains $child.Name) {
            throw "CGCE-OPS-RESTORE-RECEIPT foreign recovery receipt"
        }
    }
    $previous = Get-CgceSha256 $RecoveryIntentPath
    $bindings = New-Object 'Collections.Generic.List[object]'
    for ($index = 0; $index -lt 2; $index += 1) {
        $step = @($Intent.steps)[$index]
        $sequence = [int]$step.sequence
        $leaf = if ($sequence -eq 10) {
            "010-quarantine-clone.json"
        } else {
            "020-restore-original.json"
        }
        $path = Join-Path $root $leaf
        try {
            $receipt = Read-CgceJsonObject $path
        } catch {
            throw "CGCE-OPS-RESTORE-RECEIPT invalid operation receipt"
        }
        Assert-CgceExactKeys $receipt @(
            "schema_version", "kind", "run_id", "sequence", "step",
            "operation", "source_path", "destination_path",
            "before_state", "after_state", "previous_receipt_sha256",
            "completed_at_utc"
        ) "CGCE-OPS-RESTORE-RECEIPT"
        if ($receipt.schema_version -cne "1.0" -or
            $receipt.kind -cne
                "cgce_windows_discovery_restore_operation" -or
            $receipt.run_id -cne $State.run_id -or
            -not (Test-CgceRecoveryInteger `
                $receipt.sequence $sequence $sequence) -or
            $receipt.previous_receipt_sha256 -cne $previous -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.step $step.step) -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.operation $step.operation) -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.source_path $step.source_path) -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.destination_path $step.destination_path) -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.before_state $step.before_state) -or
            -not (Test-CgceRecoveryJsonEqual `
                $receipt.after_state $step.after_state)) {
            throw "CGCE-OPS-RESTORE-RECEIPT operation receipt authority drift"
        }
        $null = Assert-CgceStrictUtc `
            $receipt.completed_at_utc `
            "CGCE-OPS-RESTORE-RECEIPT"
        $previous = Get-CgceSha256 $path
        $null = $bindings.Add([pscustomobject][ordered]@{
            sequence = $sequence
            path = $path
            sha256 = $previous
        })
    }

    $finalPath = Join-Path $root "999-restore-final.json"
    try {
        $final = Read-CgceJsonObject $finalPath
    } catch {
        throw "CGCE-OPS-RESTORE-RECEIPT invalid final receipt"
    }
    Assert-CgceExactKeys $final @(
        "schema_version", "kind", "run_id", "sequence",
        "restore_intent_sha256", "previous_receipt_sha256",
        "operation_receipts", "probe_restore_final_receipt",
        "original_inventory", "restored_inventory", "completed_at_utc"
    ) "CGCE-OPS-RESTORE-RECEIPT"
    if ($final.schema_version -cne "1.0" -or
        $final.kind -cne
            "cgce_windows_discovery_restore_final" -or
        $final.run_id -cne $State.run_id -or
        -not (Test-CgceRecoveryInteger $final.sequence 999 999) -or
        $final.restore_intent_sha256 -cne
            (Get-CgceSha256 $RecoveryIntentPath) -or
        $final.previous_receipt_sha256 -cne $previous -or
        $final.operation_receipts -isnot [System.Array] -or
        -not (Test-CgceRecoveryJsonEqual `
            $final.operation_receipts `
            ([object[]]$bindings.ToArray()))) {
        throw "CGCE-OPS-RESTORE-RECEIPT final receipt authority drift"
    }
    $null = Assert-CgceStrictUtc `
        $final.completed_at_utc `
        "CGCE-OPS-RESTORE-RECEIPT"

    Assert-CgceExactKeys $final.original_inventory @(
        "path", "sha256", "tree_sha256"
    ) "CGCE-OPS-RESTORE-RECEIPT"
    Assert-CgceExactKeys $final.restored_inventory @(
        "path", "sha256", "tree_sha256"
    ) "CGCE-OPS-RESTORE-RECEIPT"
    if (-not (Test-CgceRecoveryPathEqual `
            $final.original_inventory.path `
            $State.paths.original_inventory) -or
        -not (Test-CgceRecoveryPathEqual `
            $final.restored_inventory.path `
            $State.paths.restored_inventory) -or
        $final.original_inventory.sha256 -cne
            $Intent.original_inventory_sha256 -or
        $final.original_inventory.tree_sha256 -cne
            $Intent.original_tree_sha256 -or
        -not (Test-CgceChecksum `
            $final.restored_inventory.sha256) -or
        $final.restored_inventory.tree_sha256 -cne
            $Intent.original_tree_sha256) {
        throw "CGCE-OPS-RESTORE-RECEIPT final inventory binding drift"
    }
    return $final
}

function Assert-CgceRecoveryInventoriesAndLiveTree(
    $State,
    $Intent,
    $Final
) {
    $original = Get-CgceRecoveryInventoryAuthority `
        $State `
        "original" `
        "CGCE-OPS-RESTORE-RECEIPT"
    $restored = Get-CgceRecoveryInventoryAuthority `
        $State `
        "restored" `
        "CGCE-OPS-RESTORE-RECEIPT"
    if ($original.checksum -cne
            $Final.original_inventory.sha256 -or
        $restored.checksum -cne
            $Final.restored_inventory.sha256 -or
        $original.tree_sha256 -cne
            $Intent.original_tree_sha256 -or
        $restored.tree_sha256 -cne
            $Intent.original_tree_sha256 -or
        -not (Test-CgceRecoveryJsonEqual `
            $original.entries `
            $restored.entries)) {
        throw "CGCE-OPS-RESTORE-RECEIPT restored inventory differs"
    }
    $live = @(Get-CgceRecoveryDirectoryEntries `
        $State.paths.active_saved `
        "CGCE-OPS-RESTORE-RECEIPT")
    if (-not (Test-CgceRecoveryJsonEqual `
            $restored.entries `
            $live) -or
        (Get-CgceInventoryTreeSha256 $live) -cne
            $Intent.original_tree_sha256) {
        throw "CGCE-OPS-RESTORE-RECEIPT live restored tree differs"
    }
    return $restored.checksum
}

function Complete-CgceRecoveryRunState(
    [string]$StatePath,
    [string]$RecoveryIntentPath
) {
    $fresh = Read-CgceRecoveryState $StatePath
    Assert-CgceRecoveryManualBarrier $fresh.state
    $intent = Assert-CgceRecoveryIntent `
        $fresh.state `
        $fresh.genesis `
        $fresh.checksum `
        $RecoveryIntentPath `
        -AllowRestoring
    $revision = [int64]$fresh.state.revision
    $sourceRevision = [int64]$intent.source_revision
    $legalRevisions = @(
        [int64]($sourceRevision + 1),
        [int64]($sourceRevision + 2)
    )
    if ($fresh.state.phase -cne "RESTORING" -or
        $legalRevisions -cnotcontains $revision) {
        throw "CGCE-OPS-PHASE recovery completion preimage drift"
    }
    Assert-CgceRunMarker $fresh.state
    $final = Assert-CgceRecoveryFinalJournal `
        $fresh.state `
        $intent `
        $RecoveryIntentPath
    $restoredChecksum = Assert-CgceRecoveryInventoriesAndLiveTree `
        $fresh.state `
        $intent `
        $final
    Assert-CgceRecoveryProbeRestored `
        $fresh.state `
        $final.probe_restore_final_receipt
    $fresh.state.phase = "RESTORED"
    $fresh.state.inventory_checksums.restored = $restoredChecksum
    Write-CgceRecoveryStateCas `
        $fresh.state `
        $StatePath `
        $fresh.checksum `
        "RESTORED"
}

Export-ModuleMember -Function @(
    "Test-CgceRunId",
    "Get-CgceSha256",
    "Get-CgceInventoryTreeSha256",
    "Read-CgceJsonObject",
    "Read-CgceJsonStringArray",
    "Assert-CgceControlEvidence",
    "Assert-CgceHandoffSource",
    "New-CgceRunState",
    "Read-CgceRunState",
    "Set-CgceRunPhase",
    "Write-CgceJsonAtomic",
    "Write-CgceRunState",
    "Write-CgceRecoveryRunState",
    "Block-CgceRecoveryRunState",
    "Complete-CgceRecoveryRunState",
    "Write-CgceActiveRunMarker",
    "Block-CgceRunState",
    "Assert-CgceRunMarker",
    "Enter-CgceExclusiveLock"
)
