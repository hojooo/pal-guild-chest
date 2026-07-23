Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:MaxJsonBytes = 1048576
$script:MaxJsonDepth = 64

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
[Array]::Sort($script:CgceHandoffPaths, [StringComparer]::Ordinal)

function Test-CgceRunId([string]$Value) {
    return $Value -cmatch '^r-[0-9a-f]{32}$'
}

function Test-CgceMaintenanceId([string]$Value) {
    return $Value -cmatch '^m-[0-9a-f]{32}$'
}

function Test-CgceChecksum($Value) {
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$'
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
                    if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') {
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
                        if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') {
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
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
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
    if ($Value -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
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
    return ,$files.ToArray()
}

function Assert-CgceHandoffSource([string]$HandoffRoot, [string]$ManifestPath) {
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
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$') {
            throw "CGCE-OPS-CHECKSUM malformed handoff manifest record"
        }
        $checksum = $Matches[1]
        $relative = $Matches[2]
        if ($relative -cne $script:CgceHandoffPaths[$index] -or
            -not $seen.Add($relative) -or
            $relative.Contains('\') -or $relative.StartsWith('/') -or
            $relative.StartsWith('//') -or $relative -cmatch '^[A-Za-z]:' -or
            $relative -cmatch '(^|/)\.{1,2}(/|$)' -or
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
        $cursor = $item
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
            $errorRecord.code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+$') {
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

function Assert-CgceCheckpointEvidence($State) {
    $phaseIndex = [Array]::IndexOf($script:CgcePhases, [string]$State.phase)
    if ($phaseIndex -lt 0) {
        throw "CGCE-OPS-PHASE invalid checkpoint phase"
    }
    if ($null -eq $State.inventory_checksums.original) {
        throw "CGCE-OPS-PHASE CREATED requires original inventory"
    }
    if ($phaseIndex -ge 1 -and
        $null -eq $State.inventory_checksums.backup) {
        throw "CGCE-OPS-PHASE checkpoint requires backup inventory"
    }
    if ($phaseIndex -ge 3 -and
        $null -eq $State.inventory_checksums.clone) {
        throw "CGCE-OPS-PHASE CLONE_ACTIVE requires clone inventory"
    }
    if ($phaseIndex -ge 4 -and
        $null -eq $State.probe_receipt_checksum) {
        throw "CGCE-OPS-PHASE PROBE_STAGED requires probe receipt"
    }
    if ($phaseIndex -ge 6 -and (
            $null -eq $State.process_launch_receipt_checksum -or
            $null -eq $State.process_result_receipt_checksum -or
            $null -eq $State.capture_inventory_checksum
        )) {
        throw "CGCE-OPS-PHASE CAPTURED requires process and capture receipts"
    }
    if ($phaseIndex -ge 8 -and
        $null -eq $State.inventory_checksums.restored) {
        throw "CGCE-OPS-PHASE RESTORED requires restored inventory"
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
        "CAPTURED" { @() }
        "RESTORING" { @("inventory.restored") }
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
    Assert-CgceStateShape $genesis
    Assert-CgceCheckpointEvidence $state
    Assert-CgceCheckpointEvidence $genesis
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
    [string]$Path,
    [string]$ExpectedExistingSha256 = ""
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
    $targetExists = Test-Path -LiteralPath $Path -PathType Leaf
    if (-not $targetExists -and (Test-Path -LiteralPath $Path)) {
        throw "CGCE-OPS-OUTPUT-EXISTS destination exists"
    }
    if ($targetExists -and $ExpectedExistingSha256 -eq "") {
        throw "CGCE-OPS-OUTPUT-EXISTS destination exists"
    }
    if ($ExpectedExistingSha256 -ne "") {
        if ((Split-Path -Leaf $Path) -cne "run-state.json") {
            throw "CGCE-OPS-CHECKSUM compare-and-swap is restricted to run-state.json"
        }
        if (-not (Test-CgceChecksum $ExpectedExistingSha256)) {
            throw "CGCE-OPS-CHECKSUM invalid compare-and-swap checksum"
        }
        if (-not $targetExists) {
            throw "CGCE-OPS-CHECKSUM expected existing file"
        }
        if ((Get-CgceSha256 -Path $Path) -cne $ExpectedExistingSha256) {
            throw "CGCE-OPS-CHECKSUM compare-and-swap mismatch"
        }
        $existingState = Read-CgceJsonObject -Path $Path
        Assert-CgceStateShape $existingState
        Assert-CgceStateShape $Value
        Assert-CgceCheckpointEvidence $existingState
        Assert-CgceCheckpointEvidence $Value
    }
    $json = ConvertTo-CgceJsonText $Value
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8NoBom)
    if ($targetExists) {
        if ((Get-CgceSha256 -Path $Path) -cne $ExpectedExistingSha256) {
            throw "CGCE-OPS-CHECKSUM compare-and-swap mismatch"
        }
        [System.IO.File]::Replace($temp, $Path, $null, $true)
    } else {
        [System.IO.File]::Move($temp, $Path)
    }
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
    Assert-CgceStateShape $genesis
    Assert-CgceCheckpointEvidence $genesis
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
    $validBlock = $State.phase -ceq $ExpectedPhase -and
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
    Write-CgceJsonAtomic `
        -Value $State `
        -Path $StatePath `
        -ExpectedExistingSha256 $oldChecksum
    Confirm-CgceRunStateReadBack `
        -StatePath $StatePath `
        -ExpectedChecksum $expectedChecksum `
        -ExpectedRevision ([int64]$State.revision) `
        -ExpectedPhase $State.phase
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
    Assert-CgceStateShape $genesis
    Assert-CgceStateShape $current
    Assert-CgceCheckpointEvidence $genesis
    Assert-CgceCheckpointEvidence $current
    Assert-CgceStateIdentity $genesis $current
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
    if ($Code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+$') {
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
    Assert-CgceStateShape $genesis
    Assert-CgceCheckpointEvidence $genesis
    Assert-CgceStateIdentity $genesis $state
    if ($state.outcome -cne "ACTIVE") {
        throw "CGCE-OPS-PHASE only ACTIVE state can become BLOCKED"
    }
    Assert-CgceRunMarker -State $state
    $state = Read-CgceJsonObject -Path $StatePath
    Assert-CgceStateShape $state
    Assert-CgceCheckpointEvidence $state
    Assert-CgceStateIdentity $genesis $state
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
    Assert-CgceStateShape $genesis
    Assert-CgceCheckpointEvidence $genesis
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
    "Write-CgceActiveRunMarker",
    "Block-CgceRunState",
    "Assert-CgceRunMarker",
    "Enter-CgceExclusiveLock"
)
