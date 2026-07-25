Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$contractModule = Join-Path $PSScriptRoot "CgceDiscovery.Contract.psm1"
Import-Module $contractModule | Out-Null
$filesModule = Join-Path $PSScriptRoot "CgceDiscovery.Files.psm1"
Import-Module $filesModule | Out-Null

$script:CgceTestProbeCrashSeam = $null
$script:CgceTestActivitySnapshotSeam = $null
$script:CgceTestRootProcessRecordSeam = $null
$script:CgceTestProcessRecordsSeam = $null
$script:CgceTestLaunchReceiptSeam = $null
$script:CgceTestProcessCrashSeam = $null
$script:CgceTestProbeRestoreMutationSeam = $null
$script:CgceFreshModsText = "CGCEDiscoveryInventory : 1`r`n"
$script:CgceSnapshotNames = @(
    "MODS_TXT",
    "OBJECT_DUMP",
    "CXX_HEADER_DUMP",
    "UE4SS_LOG",
    "PROBE_SOURCE"
)

function Get-CgceRuntimeUtcNow {
    return [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-CgceRuntimeExactKeys(
    $Value,
    [string[]]$Expected,
    [string]$Code
) {
    if ($null -eq $Value -or $Value -is [string]) {
        throw "$Code object required"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Expected.Count) {
        throw "$Code exact key set required"
    }
    for ($index = 0; $index -lt $Expected.Count; $index += 1) {
        if ($actual[$index] -cne $Expected[$index]) {
            throw "$Code exact key order required"
        }
    }
}

function Test-CgceRuntimeChecksum($Value) {
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}\z'
}

function Test-CgceRuntimeInteger(
    $Value,
    [int64]$Minimum,
    [int64]$Maximum
) {
    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
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

function Test-CgceRuntimeUtcTimestamp($Value) {
    if ($Value -isnot [string]) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )
}

function ConvertFrom-CgceRuntimeUtcTimestamp($Value, [string]$Code) {
    if (-not (Test-CgceRuntimeUtcTimestamp $Value)) {
        throw "$Code invalid UTC timestamp"
    }
    return [DateTime]::ParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal
    )
}

function ConvertTo-CgceCanonicalRuntimePath([string]$Path, [string]$Code) {
    try {
        return Resolve-CgceCanonicalPath -Path $Path -MustExist $false
    } catch {
        throw "$Code invalid canonical path"
    }
}

function Test-CgceRuntimePathEqual([string]$Left, [string]$Right) {
    return $Left.Equals($Right, [StringComparison]::OrdinalIgnoreCase)
}

function Add-CgceUInt32BigEndian(
    [System.IO.MemoryStream]$Stream,
    [uint32]$Value
) {
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Add-CgceUInt64BigEndian(
    [System.IO.MemoryStream]$Stream,
    [uint64]$Value
) {
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Get-CgceBytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-CgceFramedStringArraySha256(
    [string]$Domain,
    [string[]]$Values
) {
    if ($null -eq $Values) {
        throw "CGCE-OPS-ARGUMENT dense string array required"
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.MemoryStream
    try {
        $domainBytes = $encoding.GetBytes($Domain)
        $stream.Write($domainBytes, 0, $domainBytes.Length)
        $stream.WriteByte(0)
        Add-CgceUInt32BigEndian -Stream $stream -Value ([uint32]$Values.Count)
        foreach ($value in $Values) {
            if ($value -isnot [string]) {
                throw "CGCE-OPS-ARGUMENT dense string array required"
            }
            $bytes = $encoding.GetBytes($value)
            Add-CgceUInt32BigEndian -Stream $stream -Value ([uint32]$bytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        return Get-CgceBytesSha256 -Bytes $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Get-CgceTreeSha256([object[]]$Entries) {
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.MemoryStream
    try {
        $domain = $encoding.GetBytes("CGCE-TREE-1")
        $stream.Write($domain, 0, $domain.Length)
        $stream.WriteByte(0)
        Add-CgceUInt32BigEndian -Stream $stream -Value ([uint32]$Entries.Count)
        foreach ($entry in $Entries) {
            $pathBytes = $encoding.GetBytes([string]$entry.relative_path)
            Add-CgceUInt32BigEndian -Stream $stream -Value ([uint32]$pathBytes.Length)
            $stream.Write($pathBytes, 0, $pathBytes.Length)
            Add-CgceUInt64BigEndian -Stream $stream -Value ([uint64]$entry.length)
            $hashBytes = New-Object byte[] 32
            for ($index = 0; $index -lt 32; $index += 1) {
                $hashBytes[$index] = [Convert]::ToByte(
                    $entry.sha256.Substring($index * 2, 2),
                    16
                )
            }
            $stream.Write($hashBytes, 0, $hashBytes.Length)
        }
        return Get-CgceBytesSha256 -Bytes $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Assert-CgceServerArguments([string[]]$Arguments) {
    if ($null -eq $Arguments -or $Arguments.Count -gt 4096) {
        throw "CGCE-OPS-ARGUMENT argument array is required"
    }
    $blocked = @(
        "-publiclobby",
        "-AdminPassword",
        "-ServerPassword",
        "-RCONPassword",
        "-RESTAPIKey"
    )
    foreach ($argument in $Arguments) {
        if ($argument -isnot [string] -or
            [string]::IsNullOrEmpty($argument) -or
            $argument.Length -gt 4096 -or
            $argument -cnotmatch '^[-A-Za-z0-9_=.:/\\]+\z') {
            throw "CGCE-OPS-ARGUMENT unsafe native argument token"
        }
        foreach ($prefix in $blocked) {
            if ($argument.StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "CGCE-OPS-ARGUMENT public or secret-bearing argument"
            }
        }
    }
}

function ConvertTo-CgceWindowsCommandLineArgument([string]$Argument) {
    if ($null -eq $Argument -or $Argument.IndexOf([char]0) -ge 0) {
        throw "CGCE-OPS-ARGUMENT invalid native argument"
    }
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes += 1
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                $null = $builder.Append(
                    ([string][char]92) * ($backslashes * 2)
                )
            }
            $null = $builder.Append([char]92)
            $null = $builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append(
                ([string][char]92) * $backslashes
            )
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append(
            ([string][char]92) * ($backslashes * 2)
        )
    }
    $null = $builder.Append([char]34)
    return $builder.ToString()
}

function ConvertTo-CgceWindowsCommandLine([string[]]$Arguments) {
    if ($null -eq $Arguments) {
        throw "CGCE-OPS-ARGUMENT argument array is required"
    }
    $quoted = New-Object 'Collections.Generic.List[string]'
    foreach ($argument in $Arguments) {
        $null = $quoted.Add(
            (ConvertTo-CgceWindowsCommandLineArgument -Argument $argument)
        )
    }
    return [string]::Join(" ", $quoted.ToArray())
}

function ConvertTo-CgceRuntimeExecutablePaths([string[]]$ExecutablePaths) {
    if ($null -eq $ExecutablePaths -or $ExecutablePaths.Count -eq 0 -or
        $ExecutablePaths.Count -gt 4096) {
        throw "CGCE-OPS-PROCESS-QUERY exhaustive executable paths required"
    }
    $result = New-Object 'Collections.Generic.List[string]'
    $seen = New-Object 'Collections.Generic.HashSet[string]' `
        -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $ExecutablePaths) {
        if ($path -isnot [string] -or
            [string]::IsNullOrWhiteSpace($path) -or
            $path.Length -gt 4096) {
            throw "CGCE-OPS-PROCESS-QUERY invalid executable path"
        }
        $canonical = ConvertTo-CgceCanonicalRuntimePath `
            -Path $path `
            -Code "CGCE-OPS-PROCESS-QUERY"
        if (-not $seen.Add($canonical)) {
            throw "CGCE-OPS-PROCESS-QUERY duplicate executable path"
        }
        $null = $result.Add($canonical)
    }
    return [string[]]$result.ToArray()
}

function ConvertTo-CgceRuntimePorts([int[]]$Ports) {
    if ($null -eq $Ports -or $Ports.Count -eq 0) {
        throw "CGCE-OPS-PORT-QUERY configured ports required"
    }
    $result = New-Object 'Collections.Generic.List[int]'
    $seen = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($port in $Ports) {
        if ($port -lt 1 -or $port -gt 65535 -or -not $seen.Add($port)) {
            throw "CGCE-OPS-PORT-QUERY invalid configured port"
        }
        $null = $result.Add($port)
    }
    return [int[]]$result.ToArray()
}

function Get-CgceRuntimeActivitySnapshot {
    if ($null -ne $script:CgceTestActivitySnapshotSeam) {
        return & $script:CgceTestActivitySnapshotSeam
    }
    try {
        $null = Get-Command "Get-CimInstance" -ErrorAction Stop
        $processes = @(Get-CimInstance -ClassName "Win32_Process" -ErrorAction Stop)
        $cim = $true
    } catch {
        $processes = @()
        $cim = $false
    }
    try {
        $null = Get-Command "Get-NetTCPConnection" -ErrorAction Stop
        $tcp = @(Get-NetTCPConnection -ErrorAction Stop)
        $tcpOk = $true
    } catch {
        $tcp = @()
        $tcpOk = $false
    }
    try {
        $null = Get-Command "Get-NetUDPEndpoint" -ErrorAction Stop
        $udp = @(Get-NetUDPEndpoint -ErrorAction Stop)
        $udpOk = $true
    } catch {
        $udp = @()
        $udpOk = $false
    }
    return [pscustomobject]@{
        cim_available = $cim
        tcp_available = $tcpOk
        udp_available = $udpOk
        processes = [object[]]$processes
        tcp = [object[]]$tcp
        udp = [object[]]$udp
    }
}

function ConvertTo-CgceCanonicalProcessFileTime([int64]$FileTimeUtc) {
    if ($FileTimeUtc -lt 1) {
        throw "CGCE-OPS-PROCESS-QUERY invalid process creation time"
    }
    $remainder = $FileTimeUtc % 10
    return [int64]($FileTimeUtc - $remainder)
}

function Get-CgceProcessCreationFileTime($ProcessRecord) {
    if ($ProcessRecord.PSObject.Properties["CreationTimeFileTimeUtc"] -ne $null) {
        return ConvertTo-CgceCanonicalProcessFileTime `
            ([int64]$ProcessRecord.CreationTimeFileTimeUtc)
    }
    if ($ProcessRecord.PSObject.Properties["CreationDate"] -eq $null -or
        $null -eq $ProcessRecord.CreationDate) {
        throw "CGCE-OPS-PROCESS-QUERY process creation time unavailable"
    }
    try {
        if ($ProcessRecord.CreationDate -is [DateTime]) {
            return ConvertTo-CgceCanonicalProcessFileTime (
                ([DateTime]$ProcessRecord.CreationDate).
                    ToUniversalTime().
                    ToFileTimeUtc()
            )
        }
        return ConvertTo-CgceCanonicalProcessFileTime (
            [Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$ProcessRecord.CreationDate
            ).ToUniversalTime().ToFileTimeUtc()
        )
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY invalid process creation time"
    }
}

function Get-CgceProcessRunId([string]$ReceiptRoot) {
    $canonical = ConvertTo-CgceCanonicalRuntimePath `
        -Path $ReceiptRoot `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    if ((Split-Path -Leaf $canonical) -cne "process") {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid process receipt root"
    }
    $receipts = Split-Path -Parent $canonical
    if ((Split-Path -Leaf $receipts) -cne "receipts") {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid process receipt root"
    }
    $runDirectory = Split-Path -Parent $receipts
    $runId = Split-Path -Leaf $runDirectory
    if (-not (Test-CgceRunId $runId)) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid derived run identifier"
    }
    return $runId
}

function Assert-CgceProcessReceiptDirectory([string]$ReceiptRoot) {
    if (-not (Test-Path -LiteralPath $ReceiptRoot -PathType Container)) {
        throw "CGCE-OPS-PROCESS-RECEIPT receipt root missing"
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $ReceiptRoot -Force)) {
        if ($child.PSIsContainer -or
            $child.Name -cnotmatch '^(?:000-launch|[0-9]{3}-pid|999-result|manual-recovery-required)\.json\z') {
            throw "CGCE-OPS-PROCESS-RECEIPT unknown process receipt child"
        }
    }
}

function Read-CgceLaunchReceipt([string]$Path, [string]$RunId) {
    try { $value = Read-CgceJsonObject -Path $Path } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch receipt"
    }
    Assert-CgceRuntimeExactKeys $value @(
        "schema_version", "kind", "run_id", "sequence", "created_at_utc",
        "executable_path", "executable_sha256", "working_directory",
        "allowed_executable_path_count", "allowed_executable_paths_sha256",
        "argument_count", "arguments_sha256", "timeout_seconds",
        "control_valid_until_utc",
        "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_launch" -or
        $value.run_id -cne $RunId -or
        -not (Test-CgceRuntimeInteger $value.sequence 0 0) -or
        -not (Test-CgceRuntimeUtcTimestamp $value.created_at_utc) -or
        $null -ne $value.previous_receipt_sha256 -or
        -not (Test-CgceRuntimeChecksum $value.executable_sha256) -or
        -not (Test-CgceRuntimeChecksum $value.allowed_executable_paths_sha256) -or
        -not (Test-CgceRuntimeChecksum $value.arguments_sha256) -or
        -not (Test-CgceRuntimeInteger `
            $value.allowed_executable_path_count 1 4096) -or
        -not (Test-CgceRuntimeInteger $value.argument_count 0 4096) -or
        -not (Test-CgceRuntimeInteger $value.timeout_seconds 1 86400) -or
        -not (Test-CgceRuntimeUtcTimestamp `
            $value.control_valid_until_utc)) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch receipt fields"
    }
    try {
        $createdAt = ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $value.created_at_utc `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
        $validUntil = ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $value.control_valid_until_utc `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
        $receiptDeadline = $createdAt.AddSeconds(
            [int]$value.timeout_seconds
        )
    } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch deadline"
    }
    if ($receiptDeadline -gt $validUntil) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch exceeds control validity"
    }
    $executable = ConvertTo-CgceCanonicalRuntimePath `
        $value.executable_path "CGCE-OPS-PROCESS-RECEIPT"
    $working = ConvertTo-CgceCanonicalRuntimePath `
        $value.working_directory "CGCE-OPS-PROCESS-RECEIPT"
    if (-not (Test-CgceRuntimePathEqual `
            (Split-Path -Parent $executable) $working)) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch working directory drift"
    }
    return $value
}

function Assert-CgceLaunchReceiptBinding(
    $Actual,
    $Expected,
    [string[]]$CanonicalPaths,
    [string[]]$Arguments
) {
    $actualExecutable = ConvertTo-CgceCanonicalRuntimePath `
        $Actual.executable_path "CGCE-OPS-PROCESS-RECEIPT"
    $expectedExecutable = ConvertTo-CgceCanonicalRuntimePath `
        $Expected.executable_path "CGCE-OPS-PROCESS-RECEIPT"
    $actualWorking = ConvertTo-CgceCanonicalRuntimePath `
        $Actual.working_directory "CGCE-OPS-PROCESS-RECEIPT"
    $expectedWorking = ConvertTo-CgceCanonicalRuntimePath `
        $Expected.working_directory "CGCE-OPS-PROCESS-RECEIPT"
    $expectedPathsDigest = Get-CgceFramedStringArraySha256 `
        -Domain "CGCE-PATHS-1" `
        -Values $CanonicalPaths
    $expectedArgumentsDigest = Get-CgceFramedStringArraySha256 `
        -Domain "CGCE-ARGS-1" `
        -Values $Arguments
    if ($Actual.schema_version -cne $Expected.schema_version -or
        $Actual.kind -cne $Expected.kind -or
        $Actual.run_id -cne $Expected.run_id -or
        [int64]$Actual.sequence -ne [int64]$Expected.sequence -or
        $Actual.created_at_utc -cne $Expected.created_at_utc -or
        -not (Test-CgceRuntimePathEqual `
            $actualExecutable $expectedExecutable) -or
        $Actual.executable_sha256 -cne $Expected.executable_sha256 -or
        -not (Test-CgceRuntimePathEqual $actualWorking $expectedWorking) -or
        [int64]$Actual.allowed_executable_path_count -ne
            [int64]$CanonicalPaths.Count -or
        $Actual.allowed_executable_paths_sha256 -cne $expectedPathsDigest -or
        [int64]$Actual.argument_count -ne [int64]$Arguments.Count -or
        $Actual.arguments_sha256 -cne $expectedArgumentsDigest -or
        [int64]$Actual.timeout_seconds -ne
            [int64]$Expected.timeout_seconds -or
        $Actual.control_valid_until_utc -cne
            $Expected.control_valid_until_utc -or
        $null -ne $Actual.previous_receipt_sha256) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch receipt semantic drift"
    }
}

function Read-CgcePidReceipt(
    [string]$Path,
    [string]$RunId,
    [int]$ExpectedSequence,
    [string]$PreviousChecksum
) {
    try { $value = Read-CgceJsonObject -Path $Path } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID receipt"
    }
    Assert-CgceRuntimeExactKeys $value @(
        "schema_version", "kind", "run_id", "sequence", "pid", "parent_pid",
        "executable_path", "creation_time_utc",
        "creation_time_filetime_utc", "observed_at_utc",
        "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_pid" -or
        $value.run_id -cne $RunId -or
        -not (Test-CgceRuntimeInteger `
            $value.sequence $ExpectedSequence $ExpectedSequence) -or
        -not (Test-CgceRuntimeInteger $value.pid 1 ([uint32]::MaxValue)) -or
        -not (Test-CgceRuntimeInteger `
            $value.parent_pid 0 ([uint32]::MaxValue)) -or
        -not (Test-CgceRuntimeInteger `
            $value.creation_time_filetime_utc 1 ([int64]::MaxValue)) -or
        -not (Test-CgceRuntimeUtcTimestamp $value.creation_time_utc) -or
        -not (Test-CgceRuntimeUtcTimestamp $value.observed_at_utc) -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID receipt chain"
    }
    $canonical = ConvertTo-CgceCanonicalRuntimePath `
        $value.executable_path "CGCE-OPS-PROCESS-RECEIPT"
    $expectedCreation = [DateTime]::FromFileTimeUtc(
        [int64]$value.creation_time_filetime_utc
    ).ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
    if ($value.creation_time_utc -cne $expectedCreation -or
        [DateTime]::Parse($value.observed_at_utc).ToUniversalTime() -lt
            [DateTime]::Parse($value.creation_time_utc).ToUniversalTime()) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID timestamps"
    }
    return $value
}

function Read-CgceManualRecoveryBarrier(
    [string]$Path,
    [string]$RunId,
    [string]$PreviousChecksum,
    [object[]]$PidReceipts
) {
    try { $value = Read-CgceJsonObject -Path $Path } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid manual-recovery barrier"
    }
    Assert-CgceRuntimeExactKeys $value @(
        "schema_version", "kind", "run_id", "reason", "pid", "parent_pid",
        "observed_at_utc", "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_manual_recovery" -or
        $value.run_id -cne $RunId -or
        $value.reason -cne "IDENTITY_UNREADABLE" -or
        -not (Test-CgceRuntimeInteger $value.pid 1 ([uint32]::MaxValue)) -or
        -not (Test-CgceRuntimeInteger `
            $value.parent_pid 0 ([uint32]::MaxValue)) -or
        -not (Test-CgceRuntimeUtcTimestamp $value.observed_at_utc) -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid manual-recovery barrier"
    }
    if ($PidReceipts.Count -eq 0) {
        if ([int64]$value.parent_pid -ne 0) {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid root recovery barrier"
        }
    } else {
        if (@($PidReceipts | Where-Object {
                    [int64]$_.pid -eq [int64]$value.parent_pid
                }).Count -ne 1) {
            throw "CGCE-OPS-PROCESS-RECEIPT invalid descendant recovery barrier"
        }
    }
    return $value
}

function Write-CgceManualRecoveryBarrier(
    [string]$ReceiptRoot,
    [string]$RunId,
    [int64]$ProcessId,
    [int64]$ParentPid,
    [string]$PreviousChecksum,
    [object[]]$PidReceipts
) {
    $path = Join-Path $ReceiptRoot "manual-recovery-required.json"
    if (Test-Path -LiteralPath $path) {
        throw "CGCE-OPS-MANUAL-RECOVERY manual-recovery barrier already exists"
    }
    $barrier = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_process_manual_recovery"
        run_id = $RunId
        reason = "IDENTITY_UNREADABLE"
        pid = $ProcessId
        parent_pid = $ParentPid
        observed_at_utc = (Get-CgceRuntimeUtcNow)
        previous_receipt_sha256 = $PreviousChecksum
    }
    $written = Write-CgceRuntimeJson `
        -Value $barrier `
        -Path $path `
        -Code "CGCE-OPS-MANUAL-RECOVERY"
    $readBack = Read-CgceManualRecoveryBarrier `
        -Path $path `
        -RunId $RunId `
        -PreviousChecksum $PreviousChecksum `
        -PidReceipts $PidReceipts
    if ([int64]$readBack.pid -ne $ProcessId -or
        [int64]$readBack.parent_pid -ne $ParentPid -or
        (Get-CgceSha256 -Path $path) -cne $written.checksum) {
        throw "CGCE-OPS-MANUAL-RECOVERY barrier semantic drift"
    }
}

function Assert-CgceProcessResult(
    [string]$Path,
    [string]$RunId,
    $Launch,
    [string]$LaunchChecksum,
    [object[]]$PidReceipts,
    [string]$PreviousChecksum,
    [string[]]$CanonicalPaths
) {
    $receiptRoot = Split-Path -Parent $Path
    try { $value = Read-CgceJsonObject -Path $Path } catch {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid process result"
    }
    Assert-CgceRuntimeExactKeys $value @(
        "schema_version", "kind", "run_id", "sequence",
        "launch_receipt_sha256", "previous_receipt_sha256",
        "started_at_utc", "exit_at_utc", "exit_code",
        "observed_processes", "pid_receipts"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_result" -or
        $value.run_id -cne $RunId -or
        -not (Test-CgceRuntimeInteger $value.sequence 999 999) -or
        $value.launch_receipt_sha256 -cne $LaunchChecksum -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum -or
        -not (Test-CgceRuntimeUtcTimestamp $value.started_at_utc) -or
        -not (Test-CgceRuntimeUtcTimestamp $value.exit_at_utc) -or
        -not (Test-CgceRuntimeInteger `
            $value.exit_code ([int32]::MinValue) ([int32]::MaxValue)) -or
        $value.observed_processes -isnot [System.Array] -or
        $value.pid_receipts -isnot [System.Array] -or
        $PidReceipts.Count -lt 1 -or $PidReceipts.Count -gt 998 -or
        @($value.observed_processes).Count -ne $PidReceipts.Count -or
        @($value.pid_receipts).Count -ne $PidReceipts.Count) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid process result fields"
    }
    $launchCreated = ConvertFrom-CgceRuntimeUtcTimestamp `
        -Value $Launch.created_at_utc `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    $controlDeadline = ConvertFrom-CgceRuntimeUtcTimestamp `
        -Value $Launch.control_valid_until_utc `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    $startedAt = ConvertFrom-CgceRuntimeUtcTimestamp `
        -Value $value.started_at_utc `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    $exitAt = ConvertFrom-CgceRuntimeUtcTimestamp `
        -Value $value.exit_at_utc `
        -Code "CGCE-OPS-PROCESS-RECEIPT"
    $launchDeadline = $launchCreated.AddSeconds(
        [int]$Launch.timeout_seconds
    )
    if ($startedAt -lt $launchCreated -or
        $exitAt -lt $startedAt -or
        $exitAt -gt $launchDeadline -or
        $exitAt -gt $controlDeadline) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid process result timestamps"
    }
    for ($index = 0; $index -lt $PidReceipts.Count; $index += 1) {
        $expected = $PidReceipts[$index]
        $sequence = $index + 1
        $binding = @($value.pid_receipts)[$index]
        Assert-CgceRuntimeExactKeys $binding @(
            "sequence", "path", "sha256"
        ) "CGCE-OPS-PROCESS-RECEIPT"
        $expectedPath = Join-Path $receiptRoot (
            $sequence.ToString("000") + "-pid.json"
        )
        if (-not (Test-CgceRuntimeInteger `
                $binding.sequence $sequence $sequence) -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $binding.path "CGCE-OPS-PROCESS-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $expectedPath "CGCE-OPS-PROCESS-RECEIPT")) -or
            -not (Test-CgceRuntimeChecksum $binding.sha256) -or
            $binding.sha256 -cne (Get-CgceSha256 $expectedPath)) {
            throw "CGCE-OPS-PROCESS-RECEIPT process result PID binding drift"
        }
        $observed = @($value.observed_processes)[$index]
        Assert-CgceRuntimeExactKeys $observed @(
            "sequence", "pid", "parent_pid", "executable_path",
            "creation_time_utc", "creation_time_filetime_utc"
        ) "CGCE-OPS-PROCESS-RECEIPT"
        if (-not (Test-CgceRuntimeInteger `
                $observed.sequence $sequence $sequence) -or
            -not (Test-CgceRuntimeInteger `
                $observed.pid 1 ([uint32]::MaxValue)) -or
            -not (Test-CgceRuntimeInteger `
                $observed.parent_pid 0 ([uint32]::MaxValue)) -or
            -not (Test-CgceRuntimeInteger `
                $observed.creation_time_filetime_utc 1 ([int64]::MaxValue)) -or
            -not (Test-CgceRuntimeUtcTimestamp `
                $observed.creation_time_utc) -or
            [int64]$observed.pid -ne [int64]$expected.pid -or
            [int64]$observed.parent_pid -ne [int64]$expected.parent_pid -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $observed.executable_path "CGCE-OPS-PROCESS-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $expected.executable_path "CGCE-OPS-PROCESS-RECEIPT")) -or
            $observed.creation_time_utc -cne $expected.creation_time_utc -or
            [int64]$observed.creation_time_filetime_utc -ne
                [int64]$expected.creation_time_filetime_utc) {
            throw "CGCE-OPS-PROCESS-RECEIPT observed process binding drift"
        }
        if (@($CanonicalPaths | Where-Object {
                    Test-CgceRuntimePathEqual $_ (
                        ConvertTo-CgceCanonicalRuntimePath `
                            $observed.executable_path `
                            "CGCE-OPS-PROCESS-RECEIPT"
                    )
                }).Count -ne 1) {
            throw "CGCE-OPS-PROCESS-RECEIPT observed executable not allowed"
        }
        $receiptCreated = ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $expected.creation_time_utc `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
        $receiptObserved = ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $expected.observed_at_utc `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
        if ($exitAt -lt $receiptCreated -or $exitAt -lt $receiptObserved) {
            throw "CGCE-OPS-PROCESS-RECEIPT result predates PID observation"
        }
        if ($index -eq 0 -and
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $expected.executable_path "CGCE-OPS-PROCESS-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $Launch.executable_path "CGCE-OPS-PROCESS-RECEIPT"))) {
            throw "CGCE-OPS-PROCESS-RECEIPT root PID launch binding drift"
        }
    }
}

function Read-CgceProcessReceiptChain(
    [string]$ReceiptRoot,
    [string[]]$CanonicalPaths
) {
    Assert-CgceProcessReceiptDirectory -ReceiptRoot $ReceiptRoot
    $runId = Get-CgceProcessRunId -ReceiptRoot $ReceiptRoot
    $launchPath = Join-Path $ReceiptRoot "000-launch.json"
    if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch receipt missing"
    }
    $launch = Read-CgceLaunchReceipt -Path $launchPath -RunId $runId
    $pathsDigest = Get-CgceFramedStringArraySha256 `
        -Domain "CGCE-PATHS-1" `
        -Values $CanonicalPaths
    if ([int]$launch.allowed_executable_path_count -ne $CanonicalPaths.Count -or
        $launch.allowed_executable_paths_sha256 -cne $pathsDigest) {
        throw "CGCE-OPS-PROCESS-RECEIPT executable allowlist binding mismatch"
    }
    $launchExecutable = ConvertTo-CgceCanonicalRuntimePath `
        $launch.executable_path "CGCE-OPS-PROCESS-RECEIPT"
    if (@($CanonicalPaths | Where-Object {
                Test-CgceRuntimePathEqual $_ $launchExecutable
            }).Count -ne 1) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch executable binding mismatch"
    }
    $previous = Get-CgceSha256 -Path $launchPath
    $pidReceipts = New-Object 'Collections.Generic.List[object]'
    $hasUnlisted = $false
    for ($sequence = 1; $sequence -le 998; $sequence += 1) {
        $path = Join-Path $ReceiptRoot (
            $sequence.ToString("000") + "-pid.json"
        )
        if (-not (Test-Path -LiteralPath $path)) {
            break
        }
        $receipt = Read-CgcePidReceipt `
            -Path $path `
            -RunId $runId `
            -ExpectedSequence $sequence `
            -PreviousChecksum $previous
        $receiptExecutable = ConvertTo-CgceCanonicalRuntimePath `
            $receipt.executable_path "CGCE-OPS-PROCESS-RECEIPT"
        if (@($pidReceipts.ToArray() | Where-Object {
                    [int64]$_.pid -eq [int64]$receipt.pid
                }).Count -ne 0) {
            throw "CGCE-OPS-PROCESS-RECEIPT duplicate PID identity"
        }
        if ($sequence -eq 1) {
            if ([int64]$receipt.parent_pid -ne 0 -or
                -not (Test-CgceRuntimePathEqual `
                    $receiptExecutable $launchExecutable)) {
                throw "CGCE-OPS-PROCESS-RECEIPT root PID launch binding drift"
            }
        } else {
            $parentMatches = @($pidReceipts.ToArray() | Where-Object {
                [int64]$_.pid -eq [int64]$receipt.parent_pid
            })
            if ($parentMatches.Count -ne 1) {
                throw "CGCE-OPS-PROCESS-RECEIPT descendant parent chain drift"
            }
            if ([int64]$receipt.creation_time_filetime_utc -lt
                [int64]$parentMatches[0].creation_time_filetime_utc) {
                throw "CGCE-OPS-PROCESS-RECEIPT descendant predates parent"
            }
        }
        $null = $pidReceipts.Add($receipt)
        if (@($CanonicalPaths | Where-Object {
                    Test-CgceRuntimePathEqual $_ $receiptExecutable
                }).Count -ne 1) {
            $hasUnlisted = $true
        }
        $previous = Get-CgceSha256 -Path $path
    }
    $pidFiles = @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter "*-pid.json")
    if ($pidFiles.Count -ne $pidReceipts.Count) {
        throw "CGCE-OPS-PROCESS-RECEIPT PID receipt sequence gap"
    }
    $barrierPath = Join-Path $ReceiptRoot "manual-recovery-required.json"
    if (Test-Path -LiteralPath $barrierPath -PathType Leaf) {
        $null = Read-CgceManualRecoveryBarrier `
            -Path $barrierPath `
            -RunId $runId `
            -PreviousChecksum $previous `
            -PidReceipts ([object[]]$pidReceipts.ToArray())
        throw "CGCE-OPS-MANUAL-RECOVERY durable process identity barrier"
    }
    $resultPath = Join-Path $ReceiptRoot "999-result.json"
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Assert-CgceProcessResult `
            -Path $resultPath `
            -RunId $runId `
            -Launch $launch `
            -LaunchChecksum (Get-CgceSha256 -Path $launchPath) `
            -PidReceipts ([object[]]$pidReceipts.ToArray()) `
            -PreviousChecksum $previous `
            -CanonicalPaths $CanonicalPaths
    }
    return [pscustomobject]@{
        run_id = $runId
        launch = $launch
        launch_checksum = (Get-CgceSha256 -Path $launchPath)
        pid_receipts = [object[]]$pidReceipts.ToArray()
        has_unlisted_pid_receipt = $hasUnlisted
        last_checksum = $previous
    }
}

function Assert-CgceNoServerActivity(
    [string[]]$ExecutablePaths,
    [int[]]$Ports,
    [string]$ReceiptRoot = ""
) {
    $paths = @(ConvertTo-CgceRuntimeExecutablePaths $ExecutablePaths)
    $validatedPorts = @(ConvertTo-CgceRuntimePorts $Ports)
    $chain = $null
    if (-not [string]::IsNullOrWhiteSpace($ReceiptRoot)) {
        Assert-CgceProcessReceiptDirectory -ReceiptRoot $ReceiptRoot
        if (@(Get-ChildItem -LiteralPath $ReceiptRoot -Force).Count -gt 0) {
            $chain = Read-CgceProcessReceiptChain `
                -ReceiptRoot $ReceiptRoot `
                -CanonicalPaths $paths
        }
    }
    $snapshot = Get-CgceRuntimeActivitySnapshot
    if ($null -eq $snapshot -or $snapshot.cim_available -ne $true -or
        $snapshot.processes -isnot [System.Array]) {
        throw "CGCE-OPS-PROCESS-QUERY process telemetry unavailable"
    }
    if ($snapshot.tcp_available -ne $true -or
        $snapshot.udp_available -ne $true -or
        $snapshot.tcp -isnot [System.Array] -or
        $snapshot.udp -isnot [System.Array]) {
        throw "CGCE-OPS-PORT-QUERY endpoint telemetry unavailable"
    }
    foreach ($process in @($snapshot.processes)) {
        if ($null -eq $process) { continue }
        $observedProcessId = if ($process.PSObject.Properties["ProcessId"] -ne $null) {
            [int64]$process.ProcessId
        } else { -1 }
        $pathText = if ($process.PSObject.Properties["ExecutablePath"] -ne $null) {
            [string]$process.ExecutablePath
        } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($pathText)) {
            $processPath = ConvertTo-CgceCanonicalRuntimePath `
                -Path $pathText `
                -Code "CGCE-OPS-PROCESS-QUERY"
            foreach ($allowed in $paths) {
                if (Test-CgceRuntimePathEqual $processPath $allowed) {
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
                    $fileTime = Get-CgceProcessCreationFileTime $process
                    if ((Test-CgceRuntimePathEqual $processPath `
                            (ConvertTo-CgceCanonicalRuntimePath `
                                $receipt.executable_path `
                                "CGCE-OPS-PROCESS-RECEIPT")) -and
                        [int64]$receipt.creation_time_filetime_utc -eq $fileTime) {
                        throw "CGCE-OPS-PROCESS-ACTIVE durable PID identity is active"
                    }
                }
            }
        }
    }
    foreach ($endpoint in @($snapshot.tcp)) {
        if ($null -eq $endpoint -or
            $endpoint.PSObject.Properties["LocalPort"] -eq $null -or
            $endpoint.PSObject.Properties["State"] -eq $null) {
            throw "CGCE-OPS-PORT-QUERY incomplete TCP endpoint"
        }
        $state = [string]$endpoint.State
        if ($validatedPorts -contains [int]$endpoint.LocalPort -and
            ($state.Equals("Listen", [StringComparison]::OrdinalIgnoreCase) -or
                $state.Equals("Established", [StringComparison]::OrdinalIgnoreCase))) {
            throw "CGCE-OPS-PORT-ACTIVE configured TCP port active"
        }
    }
    foreach ($endpoint in @($snapshot.udp)) {
        if ($null -eq $endpoint -or
            $endpoint.PSObject.Properties["LocalPort"] -eq $null) {
            throw "CGCE-OPS-PORT-QUERY incomplete UDP endpoint"
        }
        if ($validatedPorts -contains [int]$endpoint.LocalPort) {
            throw "CGCE-OPS-PORT-ACTIVE configured UDP port active"
        }
    }
}

function Assert-CgceNoForeignRunArtifacts(
    [string]$ServerRoot,
    [string]$Ue4ssRoot,
    [string]$RunId
) {
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-FOREIGN-ARTIFACT invalid run identifier"
    }
    $server = ConvertTo-CgceCanonicalRuntimePath `
        $ServerRoot "CGCE-OPS-FOREIGN-ARTIFACT"
    $ue4ss = ConvertTo-CgceCanonicalRuntimePath `
        $Ue4ssRoot "CGCE-OPS-FOREIGN-ARTIFACT"
    if (Test-Path -LiteralPath (Join-Path $server ".cgce-discovery-active.json")) {
        throw "CGCE-OPS-FOREIGN-ARTIFACT active marker exists"
    }
    $palRoot = Join-Path $server "Pal"
    if (Test-Path -LiteralPath $palRoot -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $palRoot -Force)) {
            if ($item.Name -like "Saved.cgce-original-*") {
                throw "CGCE-OPS-FOREIGN-ARTIFACT inactive original exists"
            }
        }
    }
    $mods = Join-Path $ue4ss "Mods"
    if (Test-Path -LiteralPath (Join-Path $mods "CGCEDiscoveryInventory")) {
        throw "CGCE-OPS-PROBE-EXISTS staged inventory probe exists"
    }
    foreach ($parent in @($ue4ss, $mods)) {
        if (Test-Path -LiteralPath $parent -PathType Container) {
            foreach ($item in @(Get-ChildItem -LiteralPath $parent -Force)) {
                if ($item.Name -like "*.cgce-original-*") {
                    throw "CGCE-OPS-FOREIGN-ARTIFACT UE4SS original exists"
                }
            }
        }
    }
    $modsTxt = Join-Path $mods "mods.txt"
    if (Test-Path -LiteralPath $modsTxt -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($modsTxt)) {
            if ($line -match '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?\z') {
                throw "CGCE-OPS-MODS-TXT inventory probe already enabled"
            }
        }
    }
}

function Assert-CgceRuntimePaths($Paths, [string]$RunDirectory, [string]$RunId) {
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-PROBE-RECEIPT invalid run identifier"
    }
    $expected = New-CgceRunPaths `
        -ServerRoot $Paths.server_root `
        -SavedPath $Paths.active_saved `
        -Ue4ssRoot $Paths.ue4ss_root `
        -RunRoot $Paths.run_root `
        -RunId $RunId
    $actualKeys = @($Paths.PSObject.Properties | ForEach-Object { $_.Name })
    $expectedKeys = @($expected.PSObject.Properties | ForEach-Object { $_.Name })
    if ([string]::Join(",", $actualKeys) -cne
        [string]::Join(",", $expectedKeys)) {
        throw "CGCE-OPS-PROBE-RECEIPT Paths key drift"
    }
    foreach ($key in $expectedKeys) {
        if (-not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath $Paths.$key "CGCE-OPS-PROBE-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath $expected.$key "CGCE-OPS-PROBE-RECEIPT"))) {
            throw "CGCE-OPS-PROBE-RECEIPT Paths value drift"
        }
    }
    if (-not (Test-CgceRuntimePathEqual `
            (ConvertTo-CgceCanonicalRuntimePath $RunDirectory "CGCE-OPS-PROBE-RECEIPT") `
            $expected.run_directory)) {
        throw "CGCE-OPS-PROBE-RECEIPT run directory drift"
    }
}

function New-CgceArtifactState([string]$Path, [string]$Type) {
    $present = if ($Type -ceq "FILE") {
        Test-Path -LiteralPath $Path -PathType Leaf
    } else {
        Test-Path -LiteralPath $Path -PathType Container
    }
    if (-not $present) {
        return [pscustomobject][ordered]@{
            artifact_type = $Type
            present = $false
            length = $null
            sha256 = $null
            tree_sha256 = $null
        }
    }
    if ($Type -ceq "FILE") {
        $item = Get-Item -LiteralPath $Path -Force
        return [pscustomobject][ordered]@{
            artifact_type = "FILE"
            present = $true
            length = [int64]$item.Length
            sha256 = (Get-CgceSha256 -Path $Path)
            tree_sha256 = $null
        }
    }
    $inventory = @(Get-CgceTreeInventory -Root $Path)
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $true
        length = $null
        sha256 = $null
        tree_sha256 = (Get-CgceTreeSha256 -Entries $inventory)
    }
}

function New-CgceStatePair($Source, $Destination) {
    return [pscustomobject][ordered]@{
        source = $Source
        destination = $Destination
    }
}

function Test-CgceArtifactStateEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    if ($Left.artifact_type -isnot [string] -or
        $Right.artifact_type -isnot [string] -or
        $Left.artifact_type -cne $Right.artifact_type -or
        $Left.present -isnot [bool] -or $Right.present -isnot [bool] -or
        [bool]$Left.present -ne [bool]$Right.present) {
        return $false
    }
    if ($null -eq $Left.length -or $null -eq $Right.length) {
        if ($null -ne $Left.length -or $null -ne $Right.length) {
            return $false
        }
    } elseif (-not (Test-CgceRuntimeInteger `
            $Left.length 0 ([int64]::MaxValue)) -or
        -not (Test-CgceRuntimeInteger `
            $Right.length 0 ([int64]::MaxValue)) -or
        [decimal]$Left.length -ne [decimal]$Right.length) {
        return $false
    }
    foreach ($key in @("sha256", "tree_sha256")) {
        if ($null -eq $Left.$key -or $null -eq $Right.$key) {
            if ($null -ne $Left.$key -or $null -ne $Right.$key) {
                return $false
            }
        } elseif ($Left.$key -isnot [string] -or
            $Right.$key -isnot [string] -or
            $Left.$key -cne $Right.$key) {
            return $false
        }
    }
    return $true
}

function Test-CgceStatePairEqual($Left, $Right) {
    return (Test-CgceArtifactStateEqual $Left.source $Right.source) -and
        (Test-CgceArtifactStateEqual $Left.destination $Right.destination)
}

function Assert-CgceProbePathObjectsEqual($Expected, $Actual) {
    $expectedKeys = @($Expected.PSObject.Properties | ForEach-Object { $_.Name })
    $actualKeys = @($Actual.PSObject.Properties | ForEach-Object { $_.Name })
    if ([string]::Join(",", $expectedKeys) -cne
        [string]::Join(",", $actualKeys)) {
        throw "CGCE-OPS-PROBE-RECEIPT probe path key drift"
    }
    foreach ($key in $expectedKeys) {
        if (-not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $Expected.$key "CGCE-OPS-PROBE-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $Actual.$key "CGCE-OPS-PROBE-RECEIPT"))) {
            throw "CGCE-OPS-PROBE-RECEIPT probe path value drift"
        }
    }
}

function Invoke-CgceProbeCrash([string]$Point) {
    if ($null -ne $script:CgceTestProbeCrashSeam) {
        $null = & $script:CgceTestProbeCrashSeam $Point
    }
}

function Assert-CgceProbeRestoreFreshGuard(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId
) {
    $state = Read-CgceRunState `
        -RunRoot $Paths.run_root `
        -RunId $RunId
    Assert-CgceRuntimePaths $state.paths $RunDirectory $RunId
    foreach ($record in @($state.errors)) {
        if ($record.code -ceq "CGCE-OPS-MANUAL-RECOVERY") {
            throw "CGCE-OPS-MANUAL-RECOVERY persisted manual recovery barrier"
        }
    }
    Assert-CgceRunMarker $state
    Assert-CgceNoServerActivity `
        -ExecutablePaths @($state.server_process_paths) `
        -Ports @($state.listener_ports) `
        -ReceiptRoot $state.paths.process_receipts
}

function Invoke-CgceProbeRestoreMutationGuard(
    [string]$Point,
    $Context
) {
    if ($null -eq $Context) {
        throw "CGCE-OPS-PROBE-RECEIPT recovery guard context required"
    }
    if ($null -ne $script:CgceTestProbeRestoreMutationSeam) {
        $null = & $script:CgceTestProbeRestoreMutationSeam $Point
    }
    Assert-CgceProbeRestoreFreshGuard `
        $Context.paths `
        $Context.run_directory `
        $Context.run_id
}

function Invoke-CgceProcessCrash([string]$Point) {
    if ($null -ne $script:CgceTestProcessCrashSeam) {
        $null = & $script:CgceTestProcessCrashSeam $Point
    }
}

function Write-CgceRuntimeJson($Value, [string]$Path, [string]$Code) {
    try {
        Write-CgceJsonAtomic -Value $Value -Path $Path
        $read = Read-CgceJsonObject -Path $Path
        $checksum = Get-CgceSha256 -Path $Path
    } catch {
        throw "$Code no-overwrite JSON write/read-back failed"
    }
    return [pscustomobject]@{ value = $read; checksum = $checksum }
}

function Move-CgceFileNoOverwrite([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY source file missing"
    }
    if (Test-Path -LiteralPath $Destination) {
        throw "CGCE-OPS-MANUAL-RECOVERY destination exists"
    }
    $sourceRoot = [IO.Path]::GetPathRoot($Source)
    $destinationRoot = [IO.Path]::GetPathRoot($Destination)
    if (-not $sourceRoot.Equals(
            $destinationRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-MANUAL-RECOVERY cross-volume file move"
    }
    Assert-CgceNoReparseInPath -Path $Source
    Assert-CgceNoReparseInPath -Path $Destination
    try { [IO.File]::Move($Source, $Destination) } catch {
        throw "CGCE-OPS-MANUAL-RECOVERY file move failed"
    }
}

function Write-CgceFreshMods([string]$Path) {
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($script:CgceFreshModsText)
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            $stream.Dispose()
        }
    } catch {
        throw "CGCE-OPS-MODS-TXT isolated mods creation failed"
    }
}

function New-CgceSnapshot(
    [string]$RunId,
    [string]$Name,
    [string]$Type,
    [string]$Path
) {
    $state = New-CgceArtifactState -Path $Path -Type $Type
    $entries = $null
    if ($state.present -and $Type -ceq "DIRECTORY") {
        $entries = [object[]]@(Get-CgceTreeInventory -Root $Path)
    }
    return [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_artifact_snapshot"
        run_id = $RunId
        artifact_name = $Name
        artifact_type = $Type
        path = $Path
        present = $state.present
        length = $state.length
        sha256 = $state.sha256
        entries = $entries
    }
}

function Get-CgceProbeDerivedPaths($Paths, [string]$RunDirectory) {
    $before = Join-Path $RunDirectory "before"
    $restore = Join-Path $Paths.probe_receipts "restore"
    return [pscustomobject][ordered]@{
        before_directory = $before
        probe_source = $null
        probe_staged = $Paths.probe_staged
        probe_quarantine = $Paths.probe_quarantine
        mods_txt = $Paths.mods_txt
        mods_original = $Paths.mods_original
        mods_test = $Paths.mods_test
        object_dump = $Paths.object_dump
        object_dump_original = $Paths.object_dump_original
        object_dump_quarantine = $Paths.object_dump_quarantine
        cxx_header_dump = $Paths.cxx_header_dump
        cxx_header_dump_original = $Paths.cxx_header_dump_original
        cxx_header_dump_quarantine = $Paths.cxx_header_dump_quarantine
        ue4ss_log = $Paths.ue4ss_log
        ue4ss_log_original = $Paths.ue4ss_log_original
        ue4ss_log_quarantine = $Paths.ue4ss_log_quarantine
        probe_receipts = $Paths.probe_receipts
        probe_restore_receipts = $restore
        probe_final_receipt = $Paths.probe_receipt
    }
}

function Write-CgceProbeOperationReceipt(
    [string]$Path,
    [string]$Kind,
    [string]$RunId,
    [int]$Sequence,
    [string]$Step,
    [string]$Operation,
    $SourcePath,
    $DestinationPath,
    $Before,
    $After,
    [string]$Previous,
    $RecoveryGuardContext = $null
) {
    $receipt = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = $Kind
        run_id = $RunId
        sequence = $Sequence
        step = $Step
        operation = $Operation
        source_path = $SourcePath
        destination_path = $DestinationPath
        before_state = $Before
        after_state = $After
        previous_receipt_sha256 = $Previous
        completed_at_utc = (Get-CgceRuntimeUtcNow)
    }
    if ($null -ne $RecoveryGuardContext) {
        Assert-CgceProbeRestoreFreshGuard `
            $RecoveryGuardContext.paths `
            $RecoveryGuardContext.run_directory `
            $RecoveryGuardContext.run_id
    }
    return Write-CgceRuntimeJson `
        -Value $receipt -Path $Path -Code "CGCE-OPS-PROBE-RECEIPT"
}

function Invoke-CgceStageStep(
    [string]$ReceiptPath,
    [string]$RunId,
    [int]$Sequence,
    [string]$Step,
    [string]$Operation,
    $SourcePath,
    [string]$DestinationPath,
    [string]$Type,
    [string]$Previous,
    [scriptblock]$Action
) {
    $padded = $Sequence.ToString("000")
    $before = New-CgceStatePair `
        $(if ($null -eq $SourcePath) { $null } else {
            New-CgceArtifactState $SourcePath $Type
        }) `
        (New-CgceArtifactState $DestinationPath $Type)
    Invoke-CgceProbeCrash "before-operation-$padded"
    $null = & $Action
    Invoke-CgceProbeCrash "after-operation-$padded"
    $after = New-CgceStatePair `
        $(if ($null -eq $SourcePath) { $null } else {
            New-CgceArtifactState $SourcePath $Type
        }) `
        (New-CgceArtifactState $DestinationPath $Type)
    Invoke-CgceProbeCrash "before-receipt-$padded"
    $written = Write-CgceProbeOperationReceipt `
        -Path $ReceiptPath -Kind "cgce_windows_discovery_probe_operation" `
        -RunId $RunId -Sequence $Sequence -Step $Step `
        -Operation $Operation -SourcePath $SourcePath `
        -DestinationPath $DestinationPath -Before $before -After $after `
        -Previous $Previous
    Invoke-CgceProbeCrash "after-receipt-$padded"
    return $written
}

function Enable-CgceInventoryProbe(
    [string]$Ue4ssRoot,
    [string]$ProbeSource,
    [string]$RunDirectory,
    [string]$RunId,
    $Paths
) {
    Assert-CgceRuntimePaths $Paths $RunDirectory $RunId
    if (-not (Test-CgceRuntimePathEqual `
            (ConvertTo-CgceCanonicalRuntimePath $Ue4ssRoot "CGCE-OPS-PROBE-EXISTS") `
            $Paths.ue4ss_root)) {
        throw "CGCE-OPS-PROBE-EXISTS UE4SS root drift"
    }
    foreach ($required in @(
        @{ path = $Paths.ue4ss_dll; type = "Leaf" },
        @{ path = (Split-Path -Parent $Paths.mods_txt); type = "Container" },
        @{ path = $Paths.mods_txt; type = "Leaf" },
        @{ path = $ProbeSource; type = "Container" }
    )) {
        if (-not (Test-Path -LiteralPath $required.path -PathType $required.type)) {
            throw "CGCE-OPS-PROBE-EXISTS required probe prerequisite missing"
        }
    }
    if (Test-Path -LiteralPath $Paths.probe_staged) {
        throw "CGCE-OPS-PROBE-EXISTS staged probe exists"
    }
    foreach ($line in [IO.File]::ReadAllLines($Paths.mods_txt)) {
        if ($line -match '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?\z') {
            throw "CGCE-OPS-MODS-TXT duplicate probe enablement"
        }
    }
    $derived = Get-CgceProbeDerivedPaths $Paths $RunDirectory
    $derived.probe_source = ConvertTo-CgceCanonicalRuntimePath `
        $ProbeSource "CGCE-OPS-PROBE-RECEIPT"
    foreach ($directory in @(
        $Paths.probe_receipts,
        $derived.before_directory
    )) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "CGCE-OPS-PROBE-RECEIPT fixed output directory missing"
        }
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) {
            throw "CGCE-OPS-PROBE-RECEIPT fixed output directory not empty"
        }
    }

    $snapshotSpecs = @(
        @("010-mods-txt.json", "MODS_TXT", "FILE", $Paths.mods_txt),
        @("020-object-dump.json", "OBJECT_DUMP", "FILE", $Paths.object_dump),
        @("030-cxx-header-dump.json", "CXX_HEADER_DUMP", "DIRECTORY", $Paths.cxx_header_dump),
        @("040-ue4ss-log.json", "UE4SS_LOG", "FILE", $Paths.ue4ss_log),
        @("050-probe-source.json", "PROBE_SOURCE", "DIRECTORY", $derived.probe_source)
    )
    $bindings = New-Object 'Collections.Generic.List[object]'
    $snapshots = @{}
    foreach ($spec in $snapshotSpecs) {
        $snapshotPath = Join-Path $derived.before_directory $spec[0]
        $snapshot = New-CgceSnapshot $RunId $spec[1] $spec[2] $spec[3]
        $written = Write-CgceRuntimeJson `
            -Value $snapshot -Path $snapshotPath -Code "CGCE-OPS-PROBE-RECEIPT"
        $snapshots[$spec[1]] = $snapshot
        $null = $bindings.Add([pscustomobject][ordered]@{
            artifact_name = $spec[1]
            snapshot_path = $snapshotPath
            snapshot_sha256 = $written.checksum
        })
    }
    $intent = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_probe_intent"
        run_id = $RunId
        created_at_utc = (Get-CgceRuntimeUtcNow)
        run_directory = $Paths.run_directory
        ue4ss_root = $Paths.ue4ss_root
        paths = $derived
        snapshots = [object[]]$bindings.ToArray()
    }
    $intentWrite = Write-CgceRuntimeJson `
        -Value $intent -Path $Paths.probe_intent -Code "CGCE-OPS-PROBE-RECEIPT"
    $previous = $intentWrite.checksum
    $receiptBindings = New-Object 'Collections.Generic.List[object]'

    $stagingSteps = @(
        @{
            sequence = 10; name = "010-preserve-mods.json"
            step = "PRESERVE_MODS"; op = "MOVE_FILE"
            source = $Paths.mods_txt; destination = $Paths.mods_original
            type = "FILE"; action = {
                Move-CgceFileNoOverwrite $Paths.mods_txt $Paths.mods_original
            }
        },
        @{
            sequence = 20; name = "020-create-test-mods.json"
            step = "CREATE_TEST_MODS"; op = "CREATE_FILE"
            source = $null; destination = $Paths.mods_txt
            type = "FILE"; action = { Write-CgceFreshMods $Paths.mods_txt }
        },
        @{
            sequence = 30; name = "030-preserve-object-dump.json"
            step = "PRESERVE_OBJECT_DUMP"
            op = $(if ($snapshots.OBJECT_DUMP.present) { "MOVE_FILE" } else { "VERIFY_ABSENT" })
            source = $Paths.object_dump; destination = $Paths.object_dump_original
            type = "FILE"; action = $(if ($snapshots.OBJECT_DUMP.present) {{
                Move-CgceFileNoOverwrite $Paths.object_dump $Paths.object_dump_original
            }} else {{ if (Test-Path $Paths.object_dump) { throw "CGCE-OPS-MANUAL-RECOVERY output appeared" } }})
        },
        @{
            sequence = 40; name = "040-preserve-cxx-header-dump.json"
            step = "PRESERVE_CXX_HEADER_DUMP"
            op = $(if ($snapshots.CXX_HEADER_DUMP.present) { "MOVE_DIRECTORY" } else { "VERIFY_ABSENT" })
            source = $Paths.cxx_header_dump; destination = $Paths.cxx_header_dump_original
            type = "DIRECTORY"; action = $(if ($snapshots.CXX_HEADER_DUMP.present) {{
                Move-CgceDirectoryNoOverwrite $Paths.cxx_header_dump $Paths.cxx_header_dump_original
            }} else {{ if (Test-Path $Paths.cxx_header_dump) { throw "CGCE-OPS-MANUAL-RECOVERY output appeared" } }})
        },
        @{
            sequence = 50; name = "050-preserve-ue4ss-log.json"
            step = "PRESERVE_UE4SS_LOG"
            op = $(if ($snapshots.UE4SS_LOG.present) { "MOVE_FILE" } else { "VERIFY_ABSENT" })
            source = $Paths.ue4ss_log; destination = $Paths.ue4ss_log_original
            type = "FILE"; action = $(if ($snapshots.UE4SS_LOG.present) {{
                Move-CgceFileNoOverwrite $Paths.ue4ss_log $Paths.ue4ss_log_original
            }} else {{ if (Test-Path $Paths.ue4ss_log) { throw "CGCE-OPS-MANUAL-RECOVERY output appeared" } }})
        },
        @{
            sequence = 60; name = "060-stage-probe.json"
            step = "STAGE_PROBE"; op = "COPY_DIRECTORY"
            source = $derived.probe_source; destination = $Paths.probe_staged
            type = "DIRECTORY"; action = {
                $null = Copy-CgceTreeVerified `
                    -Source $derived.probe_source `
                    -Destination $Paths.probe_staged
            }
        }
    )
    foreach ($step in $stagingSteps) {
        $receiptPath = Join-Path $Paths.probe_receipts $step.name
        $written = Invoke-CgceStageStep `
            -ReceiptPath $receiptPath -RunId $RunId `
            -Sequence $step.sequence -Step $step.step -Operation $step.op `
            -SourcePath $step.source -DestinationPath $step.destination `
            -Type $step.type -Previous $previous -Action $step.action
        $previous = $written.checksum
        $null = $receiptBindings.Add([pscustomobject][ordered]@{
            sequence = $step.sequence
            path = $receiptPath
            sha256 = $written.checksum
        })
    }
    $modsBytes = [IO.File]::ReadAllBytes($Paths.mods_txt)
    $expectedBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        $script:CgceFreshModsText
    )
    if ([BitConverter]::ToString($modsBytes) -cne
        [BitConverter]::ToString($expectedBytes)) {
        throw "CGCE-OPS-MODS-TXT isolated mods bytes differ"
    }
    $final = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_probe_final"
        run_id = $RunId
        sequence = 999
        intent_sha256 = $intentWrite.checksum
        previous_receipt_sha256 = $previous
        mods_before_sha256 = $snapshots.MODS_TXT.sha256
        mods_after_sha256 = (Get-CgceSha256 $Paths.mods_txt)
        staged_path = $Paths.probe_staged
        paths = $derived
        operation_receipts = [object[]]$receiptBindings.ToArray()
        completed_at_utc = (Get-CgceRuntimeUtcNow)
    }
    Invoke-CgceProbeCrash "before-receipt-999"
    $finalWrite = Write-CgceRuntimeJson `
        -Value $final -Path $Paths.probe_receipt -Code "CGCE-OPS-PROBE-RECEIPT"
    Invoke-CgceProbeCrash "after-receipt-999"
    return [pscustomobject][ordered]@{
        path = $Paths.probe_receipt
        checksum = $finalWrite.checksum
    }
}

function Assert-CgceArtifactStateSchema(
    $State,
    [string]$ExpectedType,
    [string]$Code
) {
    Assert-CgceRuntimeExactKeys $State @(
        "artifact_type", "present", "length", "sha256", "tree_sha256"
    ) $Code
    if ($ExpectedType -cnotin @("FILE", "DIRECTORY") -or
        $State.artifact_type -isnot [string] -or
        $State.artifact_type -cne $ExpectedType -or
        $State.present -isnot [bool]) {
        throw "$Code invalid artifact state identity"
    }
    if (-not $State.present) {
        if ($null -ne $State.length -or $null -ne $State.sha256 -or
            $null -ne $State.tree_sha256) {
            throw "$Code absent artifact state carries data"
        }
    } elseif ($ExpectedType -ceq "FILE") {
        if (-not (Test-CgceRuntimeInteger `
                $State.length 0 ([int64]::MaxValue)) -or
            -not (Test-CgceRuntimeChecksum $State.sha256) -or
            $null -ne $State.tree_sha256) {
            throw "$Code invalid file artifact state"
        }
    } elseif ($ExpectedType -ceq "DIRECTORY") {
        if ($null -ne $State.length -or $null -ne $State.sha256 -or
            -not (Test-CgceRuntimeChecksum $State.tree_sha256)) {
            throw "$Code invalid directory artifact state"
        }
    } else {
        throw "$Code invalid artifact type"
    }
}

function Read-CgceProbeSnapshotMap($Intent, $Paths) {
    $expected = @(
        @("MODS_TXT", "010-mods-txt.json", "FILE", $Paths.mods_txt),
        @("OBJECT_DUMP", "020-object-dump.json", "FILE", $Paths.object_dump),
        @("CXX_HEADER_DUMP", "030-cxx-header-dump.json", "DIRECTORY",
            $Paths.cxx_header_dump),
        @("UE4SS_LOG", "040-ue4ss-log.json", "FILE", $Paths.ue4ss_log),
        @("PROBE_SOURCE", "050-probe-source.json", "DIRECTORY",
            $Intent.paths.probe_source)
    )
    if ($Intent.snapshots -isnot [System.Array] -or
        @($Intent.snapshots).Count -ne $expected.Count) {
        throw "CGCE-OPS-PROBE-RECEIPT snapshot binding count drift"
    }
    $map = @{}
    for ($index = 0; $index -lt $expected.Count; $index += 1) {
        $spec = $expected[$index]
        $binding = @($Intent.snapshots)[$index]
        Assert-CgceRuntimeExactKeys $binding @(
            "artifact_name", "snapshot_path", "snapshot_sha256"
        ) "CGCE-OPS-PROBE-RECEIPT"
        $expectedSnapshotPath = Join-Path `
            $Intent.paths.before_directory $spec[1]
        if ($binding.artifact_name -cne $spec[0] -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $binding.snapshot_path "CGCE-OPS-PROBE-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $expectedSnapshotPath "CGCE-OPS-PROBE-RECEIPT"))) {
            throw "CGCE-OPS-PROBE-RECEIPT snapshot binding drift"
        }
        if (-not (Test-CgceRuntimeChecksum $binding.snapshot_sha256) -or
            (Get-CgceSha256 $binding.snapshot_path) -cne $binding.snapshot_sha256) {
            throw "CGCE-OPS-MANUAL-RECOVERY snapshot checksum drift"
        }
        try { $snapshot = Read-CgceJsonObject $binding.snapshot_path } catch {
            throw "CGCE-OPS-MANUAL-RECOVERY invalid snapshot"
        }
        Assert-CgceRuntimeExactKeys $snapshot @(
            "schema_version", "kind", "run_id", "artifact_name",
            "artifact_type", "path", "present", "length", "sha256", "entries"
        ) "CGCE-OPS-PROBE-RECEIPT"
        if ($snapshot.schema_version -cne "1.0" -or
            $snapshot.kind -cne "cgce_windows_discovery_artifact_snapshot" -or
            $snapshot.run_id -cne $Intent.run_id -or
            $snapshot.artifact_name -cne $binding.artifact_name -or
            $snapshot.artifact_type -cne $spec[2] -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $snapshot.path "CGCE-OPS-PROBE-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $spec[3] "CGCE-OPS-PROBE-RECEIPT")) -or
            $snapshot.present -isnot [bool]) {
            throw "CGCE-OPS-PROBE-RECEIPT snapshot identity drift"
        }
        if (-not $snapshot.present) {
            if ($null -ne $snapshot.length -or $null -ne $snapshot.sha256 -or
                $null -ne $snapshot.entries) {
                throw "CGCE-OPS-PROBE-RECEIPT absent snapshot carries data"
            }
        } elseif ($snapshot.artifact_type -ceq "FILE") {
            if (-not (Test-CgceRuntimeInteger `
                    $snapshot.length 0 ([int64]::MaxValue)) -or
                -not (Test-CgceRuntimeChecksum $snapshot.sha256) -or
                $null -ne $snapshot.entries) {
                throw "CGCE-OPS-PROBE-RECEIPT invalid file snapshot"
            }
        } else {
            if ($null -ne $snapshot.length -or $null -ne $snapshot.sha256 -or
                $snapshot.entries -isnot [System.Array]) {
                throw "CGCE-OPS-PROBE-RECEIPT invalid directory snapshot"
            }
            Compare-CgceInventory `
                -Expected ([object[]]@($snapshot.entries)) `
                -Actual ([object[]]@($snapshot.entries))
        }
        $map[$binding.artifact_name] = $snapshot
    }
    if ([string]::Join(",", @($map.Keys | Sort-Object)) -cne
        "CXX_HEADER_DUMP,MODS_TXT,OBJECT_DUMP,PROBE_SOURCE,UE4SS_LOG") {
        throw "CGCE-OPS-PROBE-RECEIPT snapshot set drift"
    }
    if (-not $map.MODS_TXT.present -or -not $map.PROBE_SOURCE.present) {
        throw "CGCE-OPS-PROBE-RECEIPT required snapshot unexpectedly absent"
    }
    return $map
}

function Assert-CgceOperationPairState($Pair, [string]$Code) {
    Assert-CgceRuntimeExactKeys $Pair @("source", "destination") $Code
    foreach ($state in @($Pair.source, $Pair.destination)) {
        if ($null -ne $state) {
            Assert-CgceRuntimeExactKeys $state @(
                "artifact_type", "present", "length", "sha256", "tree_sha256"
            ) $Code
            if ($state.artifact_type -isnot [string] -or
                @("FILE", "DIRECTORY") -cnotcontains $state.artifact_type) {
                throw "$Code invalid operation artifact type"
            }
            Assert-CgceArtifactStateSchema `
                $state $state.artifact_type $Code
        }
    }
}

function New-CgceExpectedStageDefinitions($Paths, $Snapshots) {
    $freshBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        $script:CgceFreshModsText
    )
    $freshMods = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true
        length = [int64]$freshBytes.Length
        sha256 = (Get-CgceBytesSha256 $freshBytes)
        tree_sha256 = $null
    }
    $absentFile = New-CgceAbsentArtifactState "FILE"
    $absentDirectory = New-CgceAbsentArtifactState "DIRECTORY"
    $modsBefore = Get-CgceSnapshotState $Snapshots.MODS_TXT
    $objectBefore = Get-CgceSnapshotState $Snapshots.OBJECT_DUMP
    $headerBefore = Get-CgceSnapshotState $Snapshots.CXX_HEADER_DUMP
    $logBefore = Get-CgceSnapshotState $Snapshots.UE4SS_LOG
    $probeBefore = Get-CgceSnapshotState $Snapshots.PROBE_SOURCE
    return @(
        [pscustomobject]@{
            sequence = 10; file_name = "010-preserve-mods.json"
            step = "PRESERVE_MODS"; operation = "MOVE_FILE"
            source = $Paths.mods_txt; destination = $Paths.mods_original
            type = "FILE"
            before = (New-CgceStatePair $modsBefore $absentFile)
            after = (New-CgceStatePair $absentFile $modsBefore)
        },
        [pscustomobject]@{
            sequence = 20; file_name = "020-create-test-mods.json"
            step = "CREATE_TEST_MODS"; operation = "CREATE_FILE"
            source = $null; destination = $Paths.mods_txt; type = "FILE"
            before = (New-CgceStatePair $null $absentFile)
            after = (New-CgceStatePair $null $freshMods)
        },
        [pscustomobject]@{
            sequence = 30; file_name = "030-preserve-object-dump.json"
            step = "PRESERVE_OBJECT_DUMP"
            operation = $(if ($Snapshots.OBJECT_DUMP.present) {
                "MOVE_FILE"
            } else { "VERIFY_ABSENT" })
            source = $Paths.object_dump
            destination = $Paths.object_dump_original; type = "FILE"
            before = (New-CgceStatePair $objectBefore $absentFile)
            after = $(if ($Snapshots.OBJECT_DUMP.present) {
                New-CgceStatePair $absentFile $objectBefore
            } else { New-CgceStatePair $absentFile $absentFile })
        },
        [pscustomobject]@{
            sequence = 40; file_name = "040-preserve-cxx-header-dump.json"
            step = "PRESERVE_CXX_HEADER_DUMP"
            operation = $(if ($Snapshots.CXX_HEADER_DUMP.present) {
                "MOVE_DIRECTORY"
            } else { "VERIFY_ABSENT" })
            source = $Paths.cxx_header_dump
            destination = $Paths.cxx_header_dump_original; type = "DIRECTORY"
            before = (New-CgceStatePair $headerBefore $absentDirectory)
            after = $(if ($Snapshots.CXX_HEADER_DUMP.present) {
                New-CgceStatePair $absentDirectory $headerBefore
            } else {
                New-CgceStatePair $absentDirectory $absentDirectory
            })
        },
        [pscustomobject]@{
            sequence = 50; file_name = "050-preserve-ue4ss-log.json"
            step = "PRESERVE_UE4SS_LOG"
            operation = $(if ($Snapshots.UE4SS_LOG.present) {
                "MOVE_FILE"
            } else { "VERIFY_ABSENT" })
            source = $Paths.ue4ss_log
            destination = $Paths.ue4ss_log_original; type = "FILE"
            before = (New-CgceStatePair $logBefore $absentFile)
            after = $(if ($Snapshots.UE4SS_LOG.present) {
                New-CgceStatePair $absentFile $logBefore
            } else { New-CgceStatePair $absentFile $absentFile })
        },
        [pscustomobject]@{
            sequence = 60; file_name = "060-stage-probe.json"
            step = "STAGE_PROBE"; operation = "COPY_DIRECTORY"
            source = $Snapshots.PROBE_SOURCE.path
            destination = $Paths.probe_staged; type = "DIRECTORY"
            before = (New-CgceStatePair $probeBefore $absentDirectory)
            after = (New-CgceStatePair $probeBefore $probeBefore)
        }
    )
}

function Read-CgceProbeStageAuthority(
    $Paths,
    [string]$RunId,
    $Intent,
    $Snapshots
) {
    $specs = @(New-CgceExpectedStageDefinitions $Paths $Snapshots)
    $allowed = @(
        "000-probe-intent.json",
        "999-probe-final.json",
        "restore"
    ) + @($specs | ForEach-Object { $_.file_name })
    foreach ($child in @(Get-ChildItem -LiteralPath $Paths.probe_receipts -Force)) {
        if ($allowed -cnotcontains $child.Name) {
            throw "CGCE-OPS-PROBE-RECEIPT unknown probe receipt child"
        }
        if ($child.PSIsContainer -and $child.Name -cne "restore") {
            throw "CGCE-OPS-PROBE-RECEIPT unexpected probe receipt directory"
        }
    }
    $intentChecksum = Get-CgceSha256 $Paths.probe_intent
    $previous = $intentChecksum
    $lastSequence = 0
    $gap = $false
    foreach ($spec in $specs) {
        $path = Join-Path $Paths.probe_receipts $spec.file_name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $gap = $true
            continue
        }
        if ($gap) {
            throw "CGCE-OPS-PROBE-RECEIPT staging receipt sequence gap"
        }
        try { $receipt = Read-CgceJsonObject $path } catch {
            throw "CGCE-OPS-PROBE-RECEIPT invalid staging receipt"
        }
        Assert-CgceRuntimeExactKeys $receipt @(
            "schema_version", "kind", "run_id", "sequence", "step",
            "operation", "source_path", "destination_path", "before_state",
            "after_state", "previous_receipt_sha256", "completed_at_utc"
        ) "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceOperationPairState $receipt.before_state "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceOperationPairState $receipt.after_state "CGCE-OPS-PROBE-RECEIPT"
        if ($receipt.schema_version -cne "1.0" -or
            $receipt.kind -cne "cgce_windows_discovery_probe_operation" -or
            $receipt.run_id -cne $RunId -or
            -not (Test-CgceRuntimeInteger `
                $receipt.sequence $spec.sequence $spec.sequence) -or
            $receipt.step -cne $spec.step -or
            $receipt.operation -cne $spec.operation -or
            -not (Test-CgceRuntimeUtcTimestamp $receipt.completed_at_utc) -or
            $receipt.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT staging receipt chain drift"
        }
        $sourceMatches = if ($null -eq $spec.source) {
            $null -eq $receipt.source_path
        } else {
            $null -ne $receipt.source_path -and
                (Test-CgceRuntimePathEqual `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $receipt.source_path "CGCE-OPS-PROBE-RECEIPT") `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $spec.source "CGCE-OPS-PROBE-RECEIPT"))
        }
        if (-not $sourceMatches -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $receipt.destination_path "CGCE-OPS-PROBE-RECEIPT") `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $spec.destination "CGCE-OPS-PROBE-RECEIPT")) -or
            -not (Test-CgceStatePairEqual $receipt.before_state $spec.before) -or
            -not (Test-CgceStatePairEqual $receipt.after_state $spec.after)) {
            throw "CGCE-OPS-PROBE-RECEIPT staging receipt matrix drift"
        }
        $previous = Get-CgceSha256 $path
        $lastSequence = [int]$spec.sequence
    }
    $finalChecksum = $null
    if (Test-Path -LiteralPath $Paths.probe_receipt -PathType Leaf) {
        if ($lastSequence -ne 60) {
            throw "CGCE-OPS-PROBE-RECEIPT final receipt without full chain"
        }
        try { $final = Read-CgceJsonObject $Paths.probe_receipt } catch {
            throw "CGCE-OPS-PROBE-RECEIPT invalid final receipt"
        }
        Assert-CgceRuntimeExactKeys $final @(
            "schema_version", "kind", "run_id", "sequence", "intent_sha256",
            "previous_receipt_sha256", "mods_before_sha256",
            "mods_after_sha256", "staged_path", "paths",
            "operation_receipts", "completed_at_utc"
        ) "CGCE-OPS-PROBE-RECEIPT"
        if ($final.schema_version -cne "1.0" -or
            $final.kind -cne "cgce_windows_discovery_probe_final" -or
            $final.run_id -cne $RunId -or
            -not (Test-CgceRuntimeInteger $final.sequence 999 999) -or
            $final.intent_sha256 -cne $intentChecksum -or
            $final.previous_receipt_sha256 -cne $previous -or
            $final.mods_before_sha256 -cne $Snapshots.MODS_TXT.sha256 -or
            -not (Test-CgceRuntimeChecksum $final.mods_after_sha256) -or
            -not (Test-CgceRuntimeUtcTimestamp $final.completed_at_utc)) {
            throw "CGCE-OPS-PROBE-RECEIPT final receipt chain drift"
        }
        Assert-CgceProbePathObjectsEqual $Intent.paths $final.paths
        if ($final.operation_receipts -isnot [System.Array] -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $final.staged_path "CGCE-OPS-PROBE-RECEIPT") `
                $Paths.probe_staged) -or
            @($final.operation_receipts).Count -ne $specs.Count) {
            throw "CGCE-OPS-PROBE-RECEIPT final path or binding count drift"
        }
        for ($index = 0; $index -lt $specs.Count; $index += 1) {
            $binding = @($final.operation_receipts)[$index]
            $spec = $specs[$index]
            $receiptPath = Join-Path $Paths.probe_receipts $spec.file_name
            Assert-CgceRuntimeExactKeys $binding @(
                "sequence", "path", "sha256"
            ) "CGCE-OPS-PROBE-RECEIPT"
            if (-not (Test-CgceRuntimeInteger `
                    $binding.sequence $spec.sequence $spec.sequence) -or
                -not (Test-CgceRuntimePathEqual `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $binding.path "CGCE-OPS-PROBE-RECEIPT") `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $receiptPath "CGCE-OPS-PROBE-RECEIPT")) -or
                -not (Test-CgceRuntimeChecksum $binding.sha256) -or
                $binding.sha256 -cne (Get-CgceSha256 $receiptPath)) {
                throw "CGCE-OPS-PROBE-RECEIPT final operation binding drift"
            }
        }
        $freshBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
            $script:CgceFreshModsText
        )
        if ($final.mods_after_sha256 -cne
            (Get-CgceBytesSha256 $freshBytes)) {
            throw "CGCE-OPS-PROBE-RECEIPT final isolated mods checksum drift"
        }
        $finalChecksum = Get-CgceSha256 $Paths.probe_receipt
    }
    return [pscustomobject]@{
        last_sequence = $lastSequence
        last_checksum = $previous
        final_checksum = $finalChecksum
    }
}

function Get-CgceSnapshotState($Snapshot) {
    if (-not $Snapshot.present) {
        return [pscustomobject][ordered]@{
            artifact_type = $Snapshot.artifact_type
            present = $false; length = $null; sha256 = $null; tree_sha256 = $null
        }
    }
    if ($Snapshot.artifact_type -ceq "FILE") {
        return [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true
            length = [int64]$Snapshot.length; sha256 = $Snapshot.sha256
            tree_sha256 = $null
        }
    }
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"; present = $true
        length = $null; sha256 = $null
        tree_sha256 = (Get-CgceTreeSha256 -Entries @($Snapshot.entries))
    }
}

function Assert-CgceStagedArtifactMatches(
    [string]$Path,
    [string]$Type,
    $Expected
) {
    Assert-CgceNoReparseInPath -Path $Path
    if (-not $Expected.present) {
        if (Test-Path -LiteralPath $Path) {
            throw "CGCE-OPS-PROBE-RECEIPT absent staged artifact appeared"
        }
        return
    }
    if ($Type -ceq "DIRECTORY") {
        Assert-CgceTreeHasNoReparsePoints -Root $Path
    }
    $actual = New-CgceArtifactState -Path $Path -Type $Type
    if (-not (Test-CgceArtifactStateEqual $actual $Expected)) {
        throw "CGCE-OPS-PROBE-RECEIPT staged artifact state drift"
    }
}

function Assert-CgceRuntimeDirectoryEmpty([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "CGCE-OPS-PROBE-RECEIPT fixed directory missing"
    }
    Assert-CgceNoReparseInPath -Path $Path
    Assert-CgceTreeHasNoReparsePoints -Root $Path
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw "CGCE-OPS-PROBE-RECEIPT fixed directory is not empty"
    }
}

function Assert-CgceInventoryProbeStaged(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFinalReceiptChecksum,
    [string]$ExpectedLaunchReceiptChecksum = ""
) {
    Assert-CgceRuntimePaths $Paths $RunDirectory $RunId
    if (-not (Test-CgceRuntimeChecksum $ExpectedFinalReceiptChecksum)) {
        throw "CGCE-OPS-PROBE-RECEIPT invalid expected final checksum"
    }
    if (-not [string]::IsNullOrEmpty($ExpectedLaunchReceiptChecksum) -and
        -not (Test-CgceRuntimeChecksum $ExpectedLaunchReceiptChecksum)) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid expected launch checksum"
    }
    Assert-CgceNoReparseInPath -Path $RunDirectory
    Assert-CgceTreeHasNoReparsePoints -Root $RunDirectory

    $recordedOriginal = @(
        Read-CgceInventory `
            -Path $Paths.original_inventory `
            -ExpectedKind "original"
    )
    $recordedBackup = @(
        Read-CgceInventory `
            -Path $Paths.backup_inventory `
            -ExpectedKind "backup"
    )
    $recordedClone = @(
        Read-CgceInventory `
            -Path $Paths.clone_inventory `
            -ExpectedKind "clone"
    )
    Compare-CgceInventory `
        -Expected $recordedOriginal `
        -Actual $recordedBackup
    Compare-CgceInventory `
        -Expected $recordedOriginal `
        -Actual $recordedClone
    Compare-CgceInventory `
        -Expected $recordedOriginal `
        -Actual @(Get-CgceTreeInventory -Root $Paths.inactive_original)
    Compare-CgceInventory `
        -Expected $recordedBackup `
        -Actual @(Get-CgceTreeInventory -Root $Paths.backup_saved)
    Compare-CgceInventory `
        -Expected $recordedClone `
        -Actual @(Get-CgceTreeInventory -Root $Paths.active_saved)

    $intentAuthority = Read-CgceProbeIntentAuthority `
        -Paths $Paths `
        -RunDirectory $RunDirectory `
        -RunId $RunId
    $authority = Read-CgceProbeStageAuthority `
        -Paths $Paths `
        -RunId $RunId `
        -Intent $intentAuthority.intent `
        -Snapshots $intentAuthority.snapshots
    if ([int]$authority.last_sequence -ne 60 -or
        $null -eq $authority.final_checksum -or
        $authority.final_checksum -cne $ExpectedFinalReceiptChecksum -or
        (Get-CgceSha256 -Path $Paths.probe_receipt) -cne
            $ExpectedFinalReceiptChecksum) {
        throw "CGCE-OPS-PROBE-RECEIPT expected final receipt mismatch"
    }

    $snapshots = $intentAuthority.snapshots
    $freshBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        $script:CgceFreshModsText
    )
    $freshMods = [pscustomobject][ordered]@{
        artifact_type = "FILE"
        present = $true
        length = [int64]$freshBytes.Length
        sha256 = (Get-CgceBytesSha256 $freshBytes)
        tree_sha256 = $null
    }
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.mods_txt `
        -Type "FILE" `
        -Expected $freshMods
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.mods_original `
        -Type "FILE" `
        -Expected (Get-CgceSnapshotState $snapshots.MODS_TXT)
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.probe_staged `
        -Type "DIRECTORY" `
        -Expected (Get-CgceSnapshotState $snapshots.PROBE_SOURCE)
    Assert-CgceStagedArtifactMatches `
        -Path $intentAuthority.intent.paths.probe_source `
        -Type "DIRECTORY" `
        -Expected (Get-CgceSnapshotState $snapshots.PROBE_SOURCE)
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.object_dump `
        -Type "FILE" `
        -Expected (New-CgceAbsentArtifactState "FILE")
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.object_dump_original `
        -Type "FILE" `
        -Expected (Get-CgceSnapshotState $snapshots.OBJECT_DUMP)
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.cxx_header_dump `
        -Type "DIRECTORY" `
        -Expected (New-CgceAbsentArtifactState "DIRECTORY")
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.cxx_header_dump_original `
        -Type "DIRECTORY" `
        -Expected (Get-CgceSnapshotState $snapshots.CXX_HEADER_DUMP)
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.ue4ss_log `
        -Type "FILE" `
        -Expected (New-CgceAbsentArtifactState "FILE")
    Assert-CgceStagedArtifactMatches `
        -Path $Paths.ue4ss_log_original `
        -Type "FILE" `
        -Expected (Get-CgceSnapshotState $snapshots.UE4SS_LOG)

    foreach ($path in @(
        $Paths.mods_test,
        $Paths.probe_quarantine,
        $Paths.object_dump_quarantine,
        $Paths.cxx_header_dump_quarantine,
        $Paths.ue4ss_log_quarantine,
        $Paths.capture_inventory,
        $Paths.restored_inventory,
        $intentAuthority.intent.paths.probe_restore_receipts
    )) {
        Assert-CgceNoReparseInPath -Path $path
        if (Test-Path -LiteralPath $path) {
            throw "CGCE-OPS-PROBE-RECEIPT pre-launch residue exists"
        }
    }
    foreach ($directory in @(
        $Paths.capture,
        $Paths.restore_receipts
    )) {
        Assert-CgceRuntimeDirectoryEmpty -Path $directory
    }
    if ([string]::IsNullOrEmpty($ExpectedLaunchReceiptChecksum)) {
        Assert-CgceRuntimeDirectoryEmpty -Path $Paths.process_receipts
    } else {
        Assert-CgceNoReparseInPath -Path $Paths.process_receipts
        Assert-CgceTreeHasNoReparsePoints -Root $Paths.process_receipts
        Assert-CgceProcessReceiptDirectory `
            -ReceiptRoot $Paths.process_receipts
        $launchPath = Join-Path $Paths.process_receipts "000-launch.json"
        $children = @(Get-ChildItem `
            -LiteralPath $Paths.process_receipts `
            -Force)
        if ($children.Count -ne 1 -or
            $children[0].Name -cne "000-launch.json" -or
            -not (Test-Path -LiteralPath $launchPath -PathType Leaf) -or
            (Get-CgceSha256 -Path $launchPath) -cne
                $ExpectedLaunchReceiptChecksum) {
            throw "CGCE-OPS-PROCESS-RECEIPT staged launch intent drift"
        }
    }
}

function Get-CgceRestoreSelectedCase(
    [string]$Name,
    [bool]$BeforePresent,
    $Active,
    $Original,
    $Quarantine,
    $Before,
    $Test,
    [bool]$AllowJournalRestored
) {
    $absent = [pscustomobject][ordered]@{
        artifact_type = $Active.artifact_type; present = $false
        length = $null; sha256 = $null; tree_sha256 = $null
    }
    $aB = Test-CgceArtifactStateEqual $Active $Before
    $aT = Test-CgceArtifactStateEqual $Active $Test
    $aN = Test-CgceArtifactStateEqual $Active $absent
    $oB = Test-CgceArtifactStateEqual $Original $Before
    $oN = Test-CgceArtifactStateEqual $Original $absent
    $qT = Test-CgceArtifactStateEqual $Quarantine $Test
    $qN = Test-CgceArtifactStateEqual $Quarantine $absent
    if ($Name -ceq "PROBE") {
        if ($aN -and $qN) { return "PROBE_NOT_STAGED" }
        if ($aT -and $qN) { return "PROBE_ACTIVE" }
        if ($aN -and $qT) { return "PROBE_ALREADY_QUARANTINED" }
    } elseif ($Name -ceq "MODS_TXT") {
        if ($aB -and $oN -and ($qN -or $qT)) {
            if ($AllowJournalRestored) { return "ORIGINAL_ALREADY_RESTORED" }
            if ($qN) { return "ORIGINAL_UNCHANGED" }
        }
        if ($aN -and $oB -and $qN) { return "ORIGINAL_PRESERVED_NO_TEST" }
        if ($aT -and $oB -and $qN) { return "TEST_ACTIVE_AND_ORIGINAL_PRESERVED" }
        if ($aN -and $oB -and $qT) { return "TEST_QUARANTINED_AND_ORIGINAL_PRESERVED" }
    } elseif (-not $BeforePresent) {
        if ($aN -and $oN -and $qN) { return "BEFORE_ABSENT_NO_TEST" }
        if ($aT -and $oN -and $qN) { return "BEFORE_ABSENT_TEST_ACTIVE" }
        if ($aN -and $oN -and $qT) { return "BEFORE_ABSENT_TEST_QUARANTINED" }
    } else {
        if ($aB -and $oN -and $qN) {
            return "BEFORE_PRESENT_ALREADY_RESTORED"
        }
        if ($aB -and $oN -and $qT -and $AllowJournalRestored) {
            return "BEFORE_PRESENT_ALREADY_RESTORED"
        }
        if ($aN -and $oB -and $qN) { return "BEFORE_PRESENT_ORIGINAL_PRESERVED_NO_TEST" }
        if ($aT -and $oB -and $qN) { return "BEFORE_PRESENT_TEST_ACTIVE_AND_ORIGINAL_PRESERVED" }
        if ($aN -and $oB -and $qT) { return "BEFORE_PRESENT_TEST_QUARANTINED_AND_ORIGINAL_PRESERVED" }
    }
    throw "CGCE-OPS-MANUAL-RECOVERY no exact restoration case"
}

function New-CgceAbsentArtifactState([string]$Type) {
    return [pscustomobject][ordered]@{
        artifact_type = $Type
        present = $false
        length = $null
        sha256 = $null
        tree_sha256 = $null
    }
}

function Assert-CgceRestorePlans([object[]]$Plans) {
    $names = @(
        "PROBE", "MODS_TXT", "OBJECT_DUMP", "CXX_HEADER_DUMP", "UE4SS_LOG"
    )
    if ($Plans.Count -ne $names.Count) {
        throw "CGCE-OPS-PROBE-RECEIPT restore plan count drift"
    }
    $probeCases = @(
        "PROBE_NOT_STAGED", "PROBE_ACTIVE", "PROBE_ALREADY_QUARANTINED"
    )
    $modsCases = @(
        "ORIGINAL_UNCHANGED", "ORIGINAL_PRESERVED_NO_TEST",
        "TEST_ACTIVE_AND_ORIGINAL_PRESERVED",
        "TEST_QUARANTINED_AND_ORIGINAL_PRESERVED",
        "ORIGINAL_ALREADY_RESTORED"
    )
    $outputCases = @(
        "BEFORE_ABSENT_NO_TEST", "BEFORE_ABSENT_TEST_ACTIVE",
        "BEFORE_ABSENT_TEST_QUARANTINED",
        "BEFORE_PRESENT_ORIGINAL_PRESERVED_NO_TEST",
        "BEFORE_PRESENT_TEST_ACTIVE_AND_ORIGINAL_PRESERVED",
        "BEFORE_PRESENT_TEST_QUARANTINED_AND_ORIGINAL_PRESERVED",
        "BEFORE_PRESENT_ALREADY_RESTORED"
    )
    for ($index = 0; $index -lt $Plans.Count; $index += 1) {
        $plan = $Plans[$index]
        Assert-CgceRuntimeExactKeys $plan @(
            "artifact_name", "selected_case", "before_present", "active_state",
            "original_state", "quarantine_state"
        ) "CGCE-OPS-PROBE-RECEIPT"
        if ($plan.artifact_name -cne $names[$index]) {
            throw "CGCE-OPS-PROBE-RECEIPT restore plan order drift"
        }
        foreach ($state in @(
            $plan.active_state, $plan.original_state, $plan.quarantine_state
        )) {
            $expectedType = if ($index -eq 0 -or $index -eq 3) {
                "DIRECTORY"
            } else { "FILE" }
            Assert-CgceArtifactStateSchema `
                $state $expectedType "CGCE-OPS-PROBE-RECEIPT"
        }
        $allowed = if ($index -eq 0) {
            $probeCases
        } elseif ($index -eq 1) {
            $modsCases
        } else {
            $outputCases
        }
        if ($allowed -cnotcontains [string]$plan.selected_case) {
            throw "CGCE-OPS-PROBE-RECEIPT restore plan case drift"
        }
        if ($plan.before_present -isnot [bool]) {
            throw "CGCE-OPS-PROBE-RECEIPT restore plan presence drift"
        }
    }
}

function Get-CgceRestoreTerminalMatrix([object[]]$Plans, $Paths) {
    Assert-CgceRestorePlans $Plans
    $matrix = New-Object 'Collections.Generic.List[object]'
    $specs = @(
        @("PROBE", "DIRECTORY", $Paths.probe_staged, $null,
            $Paths.probe_quarantine),
        @("MODS_TXT", "FILE", $Paths.mods_txt, $Paths.mods_original,
            $Paths.mods_test),
        @("OBJECT_DUMP", "FILE", $Paths.object_dump,
            $Paths.object_dump_original, $Paths.object_dump_quarantine),
        @("CXX_HEADER_DUMP", "DIRECTORY", $Paths.cxx_header_dump,
            $Paths.cxx_header_dump_original,
            $Paths.cxx_header_dump_quarantine),
        @("UE4SS_LOG", "FILE", $Paths.ue4ss_log,
            $Paths.ue4ss_log_original, $Paths.ue4ss_log_quarantine)
    )
    for ($index = 0; $index -lt $specs.Count; $index += 1) {
        $plan = $Plans[$index]
        $spec = $specs[$index]
        $absent = New-CgceAbsentArtifactState $spec[1]
        if ($index -eq 0) {
            $active = $absent
            $original = $null
            $quarantine = if ($plan.selected_case -ceq "PROBE_ACTIVE") {
                $plan.active_state
            } elseif ($plan.selected_case -ceq "PROBE_ALREADY_QUARANTINED") {
                $plan.quarantine_state
            } else { $absent }
        } else {
            $active = if ($plan.before_present) {
                if ($plan.selected_case -like "*UNCHANGED" -or
                    $plan.selected_case -like "*ALREADY_RESTORED") {
                    $plan.active_state
                } else {
                    $plan.original_state
                }
            } else { $absent }
            $original = $absent
            $quarantine = if ($plan.selected_case -like "*TEST_ACTIVE*") {
                $plan.active_state
            } elseif ($plan.selected_case -like "*TEST_QUARANTINED*") {
                $plan.quarantine_state
            } elseif ($plan.selected_case -like "*ALREADY_RESTORED") {
                $plan.quarantine_state
            } else { $absent }
        }
        $null = $matrix.Add([pscustomobject]@{
            artifact_name = $spec[0]
            type = $spec[1]
            active_path = $spec[2]
            original_path = $spec[3]
            quarantine_path = $spec[4]
            active_state = $active
            original_state = $original
            quarantine_state = $quarantine
        })
    }
    return [object[]]$matrix.ToArray()
}

function Assert-CgceRestoreTerminalMatrix([object[]]$Plans, $Paths) {
    foreach ($entry in @(Get-CgceRestoreTerminalMatrix $Plans $Paths)) {
        $liveActive = New-CgceArtifactState $entry.active_path $entry.type
        if (-not (Test-CgceArtifactStateEqual `
                $liveActive $entry.active_state)) {
            throw "CGCE-OPS-MANUAL-RECOVERY terminal active state drift"
        }
        if ($null -ne $entry.original_path) {
            $liveOriginal = New-CgceArtifactState `
                $entry.original_path $entry.type
            if (-not (Test-CgceArtifactStateEqual `
                    $liveOriginal $entry.original_state)) {
                throw "CGCE-OPS-MANUAL-RECOVERY terminal original state drift"
            }
        }
        $liveQuarantine = New-CgceArtifactState `
            $entry.quarantine_path $entry.type
        if (-not (Test-CgceArtifactStateEqual `
                $liveQuarantine $entry.quarantine_state)) {
            throw "CGCE-OPS-MANUAL-RECOVERY terminal quarantine state drift"
        }
    }
}

function Assert-CgceRestorePlansBoundToSnapshots(
    [object[]]$Plans,
    $Snapshots,
    [bool]$HasJournalAuthority
) {
    Assert-CgceRestorePlans $Plans
    $beforeStates = @(
        (Get-CgceSnapshotState $Snapshots.PROBE_SOURCE),
        (Get-CgceSnapshotState $Snapshots.MODS_TXT),
        (Get-CgceSnapshotState $Snapshots.OBJECT_DUMP),
        (Get-CgceSnapshotState $Snapshots.CXX_HEADER_DUMP),
        (Get-CgceSnapshotState $Snapshots.UE4SS_LOG)
    )
    $freshBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        $script:CgceFreshModsText
    )
    $freshMods = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true
        length = [int64]$freshBytes.Length
        sha256 = (Get-CgceBytesSha256 $freshBytes)
        tree_sha256 = $null
    }
    for ($index = 0; $index -lt $Plans.Count; $index += 1) {
        $plan = $Plans[$index]
        $before = $beforeStates[$index]
        $expectedPresence = if ($index -eq 0) {
            $false
        } else { [bool]$before.present }
        if ([bool]$plan.before_present -ne $expectedPresence) {
            throw "CGCE-OPS-PROBE-RECEIPT restore plan snapshot presence drift"
        }
        if ($plan.selected_case -like "*ALREADY_RESTORED") {
            $stageIncompleteOutput = $index -ge 2 -and
                -not $plan.quarantine_state.present
            if ((-not $HasJournalAuthority -and -not $stageIncompleteOutput) -or
                -not (Test-CgceArtifactStateEqual `
                    $plan.active_state $before) -or
                $plan.original_state.present) {
                throw "CGCE-OPS-PROBE-RECEIPT unauthorized restored plan"
            }
        }
        if ($plan.selected_case -like "*UNCHANGED") {
            if (-not (Test-CgceArtifactStateEqual `
                    $plan.active_state $before) -or
                $plan.original_state.present -or
                $plan.quarantine_state.present) {
                throw "CGCE-OPS-PROBE-RECEIPT unchanged plan drift"
            }
        }
        if ($plan.selected_case -like "*ORIGINAL_PRESERVED*") {
            if (-not (Test-CgceArtifactStateEqual `
                    $plan.original_state $before)) {
                throw "CGCE-OPS-PROBE-RECEIPT preserved original drift"
            }
        }
        $testState = if ($index -eq 0) {
            $before
        } elseif ($index -eq 1) {
            $freshMods
        } elseif ($plan.selected_case -like "*TEST_ACTIVE*") {
            $plan.active_state
        } elseif ($plan.selected_case -like "*TEST_QUARANTINED*" -or
            ($plan.selected_case -like "*ALREADY_RESTORED" -and
                $plan.quarantine_state.present)) {
            $plan.quarantine_state
        } else {
            New-CgceAbsentArtifactState $plan.active_state.artifact_type
        }
        $expectedCase = Get-CgceRestoreSelectedCase `
            $plan.artifact_name $plan.before_present `
            $plan.active_state $plan.original_state $plan.quarantine_state `
            $before $testState `
            ($HasJournalAuthority -and
                $plan.selected_case -like "*ALREADY_RESTORED")
        if ($expectedCase -cne $plan.selected_case) {
            throw "CGCE-OPS-PROBE-RECEIPT restore plan semantic drift"
        }
    }
}

function New-CgceRestoreStepDefinition(
    [int]$Sequence,
    [string]$Step,
    [string]$FileName,
    [string]$Operation,
    [string]$Source,
    [string]$Destination,
    [string]$Type,
    $Before
) {
    $after = $Before
    if ($Operation -ceq "MOVE_FILE" -or
        $Operation -ceq "MOVE_DIRECTORY") {
        $after = New-CgceStatePair `
            (New-CgceAbsentArtifactState $Type) `
            $Before.source
    }
    return [pscustomobject]@{
        sequence = $Sequence
        step = $Step
        file_name = $FileName
        operation = $Operation
        source = $Source
        destination = $Destination
        type = $Type
        before = $Before
        after = $after
    }
}

function Get-CgceRestoreStepDefinitions([object[]]$Plans, $Paths) {
    Assert-CgceRestorePlans $Plans
    $definitions = New-Object 'Collections.Generic.List[object]'

    $probe = $Plans[0]
    $probeOperation = if ($probe.selected_case -ceq "PROBE_ACTIVE") {
        "MOVE_DIRECTORY"
    } elseif ($probe.selected_case -ceq "PROBE_NOT_STAGED") {
        "VERIFY_ABSENT"
    } else { "VERIFY_RESTORED" }
    $probeBefore = New-CgceStatePair `
        $probe.active_state $probe.quarantine_state
    $null = $definitions.Add((New-CgceRestoreStepDefinition `
        10 "QUARANTINE_PROBE" "010-quarantine-probe.json" `
        $probeOperation $Paths.probe_staged $Paths.probe_quarantine `
        "DIRECTORY" $probeBefore))

    $mods = $Plans[1]
    $modsQuarantine = if (
        $mods.selected_case -ceq "TEST_ACTIVE_AND_ORIGINAL_PRESERVED"
    ) { "MOVE_FILE" } elseif (
        $mods.selected_case -ceq "ORIGINAL_PRESERVED_NO_TEST"
    ) { "VERIFY_ABSENT" } else { "VERIFY_RESTORED" }
    $modsBefore20 = New-CgceStatePair `
        $mods.active_state $mods.quarantine_state
    $mods20 = New-CgceRestoreStepDefinition `
        20 "QUARANTINE_TEST_MODS" "020-quarantine-test-mods.json" `
        $modsQuarantine $Paths.mods_txt $Paths.mods_test "FILE" $modsBefore20
    $null = $definitions.Add($mods20)
    $modsRestore = if (@(
        "ORIGINAL_PRESERVED_NO_TEST",
        "TEST_ACTIVE_AND_ORIGINAL_PRESERVED",
        "TEST_QUARANTINED_AND_ORIGINAL_PRESERVED"
    ) -contains $mods.selected_case) { "MOVE_FILE" } else { "VERIFY_RESTORED" }
    $modsBefore30 = New-CgceStatePair `
        $mods.original_state $mods20.after.source
    $null = $definitions.Add((New-CgceRestoreStepDefinition `
        30 "RESTORE_MODS" "030-restore-mods.json" `
        $modsRestore $Paths.mods_original $Paths.mods_txt `
        "FILE" $modsBefore30))

    $outputSpecs = @(
        @($Plans[2], 40, 50, "OBJECT_DUMP", $Paths.object_dump,
            $Paths.object_dump_original, $Paths.object_dump_quarantine, "FILE"),
        @($Plans[3], 60, 70, "CXX_HEADER_DUMP", $Paths.cxx_header_dump,
            $Paths.cxx_header_dump_original,
            $Paths.cxx_header_dump_quarantine, "DIRECTORY"),
        @($Plans[4], 80, 90, "UE4SS_LOG", $Paths.ue4ss_log,
            $Paths.ue4ss_log_original, $Paths.ue4ss_log_quarantine, "FILE")
    )
    foreach ($output in $outputSpecs) {
        $plan = $output[0]
        $quarantineOperation = if ($plan.selected_case -like "*TEST_ACTIVE*") {
            if ($output[7] -ceq "FILE") { "MOVE_FILE" } else { "MOVE_DIRECTORY" }
        } elseif ($plan.selected_case -like "*TEST_QUARANTINED*" -or
            $plan.selected_case -like "*ALREADY_RESTORED") {
            "VERIFY_RESTORED"
        } else { "VERIFY_ABSENT" }
        $quarantineStep = New-CgceRestoreStepDefinition `
            $output[1] ("QUARANTINE_" + $output[3]) `
            ($output[1].ToString("000") + "-quarantine-" +
                $output[3].ToLowerInvariant().Replace("_", "-") + ".json") `
            $quarantineOperation $output[4] $output[6] $output[7] `
            (New-CgceStatePair $plan.active_state $plan.quarantine_state)
        $null = $definitions.Add($quarantineStep)
        $restoreOperation = if ($plan.selected_case -in @(
                "BEFORE_PRESENT_ORIGINAL_PRESERVED_NO_TEST",
                "BEFORE_PRESENT_TEST_ACTIVE_AND_ORIGINAL_PRESERVED",
                "BEFORE_PRESENT_TEST_QUARANTINED_AND_ORIGINAL_PRESERVED"
            )) {
            if ($output[7] -ceq "FILE") { "MOVE_FILE" } else { "MOVE_DIRECTORY" }
        } elseif ($plan.selected_case -like "*ALREADY_RESTORED" -or
            $plan.selected_case -like "*UNCHANGED") {
            "VERIFY_RESTORED"
        } else { "VERIFY_ABSENT" }
        $restoreBefore = New-CgceStatePair `
            $plan.original_state $quarantineStep.after.source
        $null = $definitions.Add((New-CgceRestoreStepDefinition `
            $output[2] ("RESTORE_" + $output[3]) `
            ($output[2].ToString("000") + "-restore-" +
                $output[3].ToLowerInvariant().Replace("_", "-") + ".json") `
            $restoreOperation $output[5] $output[4] $output[7] $restoreBefore))
    }
    return [object[]]$definitions.ToArray()
}

function Invoke-CgceRestoreStep(
    [string]$ReceiptRoot,
    [string]$RunId,
    [int]$Sequence,
    [string]$Step,
    [string]$Operation,
    [string]$Source,
    [string]$Destination,
    [string]$Type,
    [string]$Previous,
    $ExpectedBefore,
    $ExpectedAfter,
    $RecoveryGuardContext
) {
    $padded = $Sequence.ToString("000")
    $receiptPath = Join-Path $ReceiptRoot "$padded-$($Step.ToLowerInvariant().Replace('_','-')).json"
    $liveBefore = New-CgceStatePair `
        (New-CgceArtifactState $Source $Type) `
        (New-CgceArtifactState $Destination $Type)
    $operationAlreadyCompleted = Test-CgceStatePairEqual `
        $liveBefore $ExpectedAfter
    if (-not (Test-CgceStatePairEqual $liveBefore $ExpectedBefore) -and
        -not $operationAlreadyCompleted) {
        throw "CGCE-OPS-MANUAL-RECOVERY restore live state drift"
    }
    Invoke-CgceProbeCrash "restore-before-operation-$padded"
    Assert-CgceProbeRestoreFreshGuard `
        $RecoveryGuardContext.paths `
        $RecoveryGuardContext.run_directory `
        $RecoveryGuardContext.run_id
    if (-not $operationAlreadyCompleted -and $Operation -ceq "MOVE_FILE") {
        if ($liveBefore.source.present -and -not $liveBefore.destination.present) {
            Move-CgceFileNoOverwrite $Source $Destination
        } else {
            throw "CGCE-OPS-MANUAL-RECOVERY file move state is ambiguous"
        }
    } elseif (-not $operationAlreadyCompleted -and
        $Operation -ceq "MOVE_DIRECTORY") {
        if ($liveBefore.source.present -and -not $liveBefore.destination.present) {
            Move-CgceDirectoryNoOverwrite $Source $Destination
        } else {
            throw "CGCE-OPS-MANUAL-RECOVERY directory move state is ambiguous"
        }
    }
    Invoke-CgceProbeCrash "restore-after-operation-$padded"
    $after = New-CgceStatePair `
        (New-CgceArtifactState $Source $Type) `
        (New-CgceArtifactState $Destination $Type)
    if (-not (Test-CgceStatePairEqual $after $ExpectedAfter)) {
        throw "CGCE-OPS-MANUAL-RECOVERY restore post-operation state drift"
    }
    Invoke-CgceProbeCrash "restore-before-receipt-$padded"
    $written = Write-CgceProbeOperationReceipt `
        -Path $receiptPath `
        -Kind "cgce_windows_discovery_probe_restore_operation" `
        -RunId $RunId -Sequence $Sequence -Step $Step `
        -Operation $Operation -SourcePath $Source `
        -DestinationPath $Destination -Before $ExpectedBefore `
        -After $ExpectedAfter `
        -Previous $Previous `
        -RecoveryGuardContext $RecoveryGuardContext
    Invoke-CgceProbeCrash "restore-after-receipt-$padded"
    return [pscustomobject]@{
        path = $receiptPath
        checksum = $written.checksum
        after = $after
    }
}

function Read-CgceProbeRestorePrefix(
    [string]$RestoreRoot,
    [string]$RunId,
    $Paths,
    $ExpectedPathObject
) {
    $intentPath = Join-Path $RestoreRoot "000-probe-restore-intent.json"
    if (-not (Test-Path -LiteralPath $intentPath -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY restore journal has no intent"
    }
    try { $intent = Read-CgceJsonObject $intentPath } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid restore intent"
    }
    Assert-CgceRuntimeExactKeys $intent @(
        "schema_version", "kind", "run_id", "sequence", "created_at_utc",
        "stage_intent_sha256", "stage_final_sha256",
        "stage_chain_last_sequence", "stage_chain_last_sha256", "paths", "plans"
    ) "CGCE-OPS-PROBE-RECEIPT"
    if ($intent.schema_version -cne "1.0" -or
        $intent.kind -cne "cgce_windows_discovery_probe_restore_intent" -or
        $intent.run_id -cne $RunId -or
        -not (Test-CgceRuntimeInteger $intent.sequence 0 0) -or
        -not (Test-CgceRuntimeUtcTimestamp $intent.created_at_utc) -or
        -not (Test-CgceRuntimeChecksum $intent.stage_intent_sha256) -or
        ($null -ne $intent.stage_final_sha256 -and
            -not (Test-CgceRuntimeChecksum $intent.stage_final_sha256)) -or
        -not (Test-CgceRuntimeInteger `
            $intent.stage_chain_last_sequence 0 60) -or
        -not (Test-CgceRuntimeChecksum $intent.stage_chain_last_sha256)) {
        throw "CGCE-OPS-PROBE-RECEIPT restore intent identity drift"
    }
    Assert-CgceProbePathObjectsEqual $ExpectedPathObject $intent.paths
    if ($intent.plans -isnot [System.Array]) {
        throw "CGCE-OPS-PROBE-RECEIPT restore plans array required"
    }
    $plans = [object[]]@($intent.plans)
    $definitions = @(Get-CgceRestoreStepDefinitions $plans $Paths)
    $allowed = @(
        "000-probe-restore-intent.json",
        "999-probe-restore-final.json"
    ) + @($definitions | ForEach-Object { $_.file_name })
    foreach ($child in @(Get-ChildItem -LiteralPath $RestoreRoot -Force)) {
        if ($child.PSIsContainer -or $allowed -cnotcontains $child.Name) {
            throw "CGCE-OPS-PROBE-RECEIPT unknown restore receipt child"
        }
    }
    $previous = Get-CgceSha256 $intentPath
    $bindings = New-Object 'Collections.Generic.List[object]'
    $gap = $false
    foreach ($definition in $definitions) {
        $path = Join-Path $RestoreRoot $definition.file_name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $gap = $true
            continue
        }
        if ($gap) {
            throw "CGCE-OPS-PROBE-RECEIPT restore receipt sequence gap"
        }
        try { $receipt = Read-CgceJsonObject $path } catch {
            throw "CGCE-OPS-PROBE-RECEIPT invalid restore receipt"
        }
        Assert-CgceRuntimeExactKeys $receipt @(
            "schema_version", "kind", "run_id", "sequence", "step",
            "operation", "source_path", "destination_path", "before_state",
            "after_state", "previous_receipt_sha256", "completed_at_utc"
        ) "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceOperationPairState $receipt.before_state "CGCE-OPS-PROBE-RECEIPT"
        Assert-CgceOperationPairState $receipt.after_state "CGCE-OPS-PROBE-RECEIPT"
        if ($receipt.schema_version -cne "1.0" -or
            $receipt.kind -cne "cgce_windows_discovery_probe_restore_operation" -or
            $receipt.run_id -cne $RunId -or
            -not (Test-CgceRuntimeInteger `
                $receipt.sequence $definition.sequence $definition.sequence) -or
            $receipt.step -cne $definition.step -or
            $receipt.operation -cne $definition.operation -or
            -not (Test-CgceRuntimeUtcTimestamp $receipt.completed_at_utc) -or
            $receipt.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT restore receipt chain drift"
        }
        if (-not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $receipt.source_path "CGCE-OPS-PROBE-RECEIPT") `
                $definition.source) -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $receipt.destination_path "CGCE-OPS-PROBE-RECEIPT") `
                $definition.destination) -or
            -not (Test-CgceStatePairEqual `
                $receipt.before_state $definition.before) -or
            -not (Test-CgceStatePairEqual `
                $receipt.after_state $definition.after)) {
            throw "CGCE-OPS-PROBE-RECEIPT restore receipt matrix drift"
        }
        $previous = Get-CgceSha256 $path
        $null = $bindings.Add([pscustomobject][ordered]@{
            sequence = [int]$definition.sequence
            path = $path
            sha256 = $previous
        })
    }
    $finalPath = Join-Path $RestoreRoot "999-probe-restore-final.json"
    $complete = Test-Path -LiteralPath $finalPath -PathType Leaf
    if ($complete -and $bindings.Count -ne 9) {
        throw "CGCE-OPS-PROBE-RECEIPT restore final without full prefix"
    }
    if ($complete) {
        try { $final = Read-CgceJsonObject $finalPath } catch {
            throw "CGCE-OPS-PROBE-RECEIPT invalid restore final"
        }
        Assert-CgceRuntimeExactKeys $final @(
            "schema_version", "kind", "run_id", "sequence",
            "restore_intent_sha256", "previous_receipt_sha256", "paths",
            "operation_receipts", "restored_states", "completed_at_utc"
        ) "CGCE-OPS-PROBE-RECEIPT"
        if ($final.schema_version -cne "1.0" -or
            $final.kind -cne "cgce_windows_discovery_probe_restore_final" -or
            $final.run_id -cne $RunId -or
            -not (Test-CgceRuntimeInteger $final.sequence 999 999) -or
            $final.restore_intent_sha256 -cne (Get-CgceSha256 $intentPath) -or
            $final.previous_receipt_sha256 -cne $previous -or
            -not (Test-CgceRuntimeUtcTimestamp $final.completed_at_utc)) {
            throw "CGCE-OPS-PROBE-RECEIPT restore final chain drift"
        }
        Assert-CgceProbePathObjectsEqual $ExpectedPathObject $final.paths
        if ($final.operation_receipts -isnot [System.Array] -or
            @($final.operation_receipts).Count -ne $bindings.Count -or
            $final.restored_states -isnot [System.Array] -or
            @($final.restored_states).Count -ne 5) {
            throw "CGCE-OPS-PROBE-RECEIPT restore final count drift"
        }
        for ($index = 0; $index -lt $bindings.Count; $index += 1) {
            $actual = @($final.operation_receipts)[$index]
            $expected = $bindings[$index]
            Assert-CgceRuntimeExactKeys $actual @(
                "sequence", "path", "sha256"
            ) "CGCE-OPS-PROBE-RECEIPT"
            if (-not (Test-CgceRuntimeInteger `
                    $actual.sequence $expected.sequence $expected.sequence) -or
                -not (Test-CgceRuntimePathEqual `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $actual.path "CGCE-OPS-PROBE-RECEIPT") `
                    (ConvertTo-CgceCanonicalRuntimePath `
                        $expected.path "CGCE-OPS-PROBE-RECEIPT")) -or
                $actual.sha256 -cne $expected.sha256) {
                throw "CGCE-OPS-PROBE-RECEIPT restore final binding drift"
            }
        }
        $terminal = @(Get-CgceRestoreTerminalMatrix $plans $Paths)
        for ($index = 0; $index -lt $terminal.Count; $index += 1) {
            $actual = @($final.restored_states)[$index]
            Assert-CgceRuntimeExactKeys $actual @(
                "artifact_name", "state"
            ) "CGCE-OPS-PROBE-RECEIPT"
            Assert-CgceArtifactStateSchema `
                $actual.state $terminal[$index].type `
                "CGCE-OPS-PROBE-RECEIPT"
            if ($actual.artifact_name -cne $terminal[$index].artifact_name -or
                -not (Test-CgceArtifactStateEqual `
                    $actual.state $terminal[$index].active_state)) {
                throw "CGCE-OPS-PROBE-RECEIPT restore final state drift"
            }
        }
    }
    return [pscustomobject]@{
        intent = $intent
        intent_checksum = (Get-CgceSha256 $intentPath)
        previous_checksum = $previous
        bindings = [object[]]$bindings.ToArray()
        definitions = [object[]]$definitions
        complete = $complete
        final = $(if ($complete) { $final } else { $null })
    }
}

function Assert-CgceNoProbeResidueWithoutIntent($Paths) {
    $artifactPaths = @(
        $Paths.probe_staged,
        $Paths.probe_quarantine,
        $Paths.mods_original,
        $Paths.mods_test,
        $Paths.object_dump_original,
        $Paths.object_dump_quarantine,
        $Paths.cxx_header_dump_original,
        $Paths.cxx_header_dump_quarantine,
        $Paths.ue4ss_log_original,
        $Paths.ue4ss_log_quarantine
    )
    foreach ($path in $artifactPaths) {
        if (Test-Path -LiteralPath $path) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe residue without intent"
        }
    }
    if (Test-Path -LiteralPath $Paths.probe_receipts -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $Paths.probe_receipts -Force).Count -gt 0) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe journal without intent"
        }
    }
    $before = Join-Path $Paths.run_directory "before"
    if (Test-Path -LiteralPath $before -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $before -Force).Count -gt 0) {
            throw "CGCE-OPS-MANUAL-RECOVERY probe snapshots without intent"
        }
    }
    if (Test-Path -LiteralPath $Paths.mods_txt -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Paths.mods_txt)) {
            if ($line -match
                '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?\z') {
                throw "CGCE-OPS-MANUAL-RECOVERY probe enablement without intent"
            }
        }
    }
}

function Read-CgceProbeIntentAuthority(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId
) {
    try { $intent = Read-CgceJsonObject $Paths.probe_intent } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid probe intent"
    }
    Assert-CgceRuntimeExactKeys $intent @(
        "schema_version", "kind", "run_id", "created_at_utc",
        "run_directory", "ue4ss_root", "paths", "snapshots"
    ) "CGCE-OPS-PROBE-RECEIPT"
    if ($intent.schema_version -cne "1.0" -or
        $intent.kind -cne "cgce_windows_discovery_probe_intent" -or
        $intent.run_id -cne $RunId -or
        -not (Test-CgceRuntimeUtcTimestamp $intent.created_at_utc) -or
        -not (Test-CgceRuntimePathEqual `
            (ConvertTo-CgceCanonicalRuntimePath `
                $intent.run_directory "CGCE-OPS-PROBE-RECEIPT") `
            $Paths.run_directory) -or
        -not (Test-CgceRuntimePathEqual `
            (ConvertTo-CgceCanonicalRuntimePath `
                $intent.ue4ss_root "CGCE-OPS-PROBE-RECEIPT") `
            $Paths.ue4ss_root)) {
        throw "CGCE-OPS-PROBE-RECEIPT probe intent identity drift"
    }
    $expectedPaths = Get-CgceProbeDerivedPaths $Paths $RunDirectory
    $expectedPaths.probe_source = ConvertTo-CgceCanonicalRuntimePath `
        $intent.paths.probe_source "CGCE-OPS-PROBE-RECEIPT"
    Assert-CgceProbePathObjectsEqual $expectedPaths $intent.paths
    $snapshots = Read-CgceProbeSnapshotMap $intent $Paths
    return [pscustomobject]@{
        intent = $intent
        checksum = (Get-CgceSha256 $Paths.probe_intent)
        snapshots = $snapshots
    }
}

function Assert-CgceInventoryProbeRestored(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId,
    [string]$ExpectedFinalReceiptChecksum = ""
) {
    Assert-CgceRuntimePaths $Paths $RunDirectory $RunId
    if (-not (Test-Path -LiteralPath $Paths.probe_intent -PathType Leaf)) {
        if (-not [string]::IsNullOrEmpty(
                $ExpectedFinalReceiptChecksum
            )) {
            throw "CGCE-OPS-PROBE-RECEIPT expected probe authority is missing"
        }
        Assert-CgceNoProbeResidueWithoutIntent $Paths
        return
    }

    $intentAuthority = Read-CgceProbeIntentAuthority `
        $Paths `
        $RunDirectory `
        $RunId
    $intent = $intentAuthority.intent
    $snapshots = $intentAuthority.snapshots
    $stage = Read-CgceProbeStageAuthority `
        $Paths `
        $RunId `
        $intent `
        $snapshots
    if (-not [string]::IsNullOrEmpty(
            $ExpectedFinalReceiptChecksum
        ) -and
        ($null -eq $stage.final_checksum -or
            $stage.final_checksum -cne
                $ExpectedFinalReceiptChecksum)) {
        throw "CGCE-OPS-PROBE-RECEIPT expected final receipt mismatch"
    }

    $restoreRoot = $intent.paths.probe_restore_receipts
    if (-not (Test-Path -LiteralPath $restoreRoot -PathType Container)) {
        throw "CGCE-OPS-PROBE-RECEIPT probe restore journal is missing"
    }
    $prefix = Read-CgceProbeRestorePrefix `
        $restoreRoot `
        $RunId `
        $Paths `
        $intent.paths
    Assert-CgceProbePathObjectsEqual `
        $intent.paths `
        $prefix.intent.paths
    if ($prefix.intent.stage_intent_sha256 -cne
            $intentAuthority.checksum -or
        $prefix.intent.stage_final_sha256 -ne
            $stage.final_checksum -or
        [int]$prefix.intent.stage_chain_last_sequence -ne
            [int]$stage.last_sequence -or
        $prefix.intent.stage_chain_last_sha256 -cne
            $stage.last_checksum) {
        throw "CGCE-OPS-PROBE-RECEIPT restore intent stage binding drift"
    }
    $plans = [object[]]@($prefix.intent.plans)
    if ($plans[0].before_present -ne $false -or
        $plans[1].before_present -ne $true -or
        $plans[2].before_present -ne
            [bool]$snapshots.OBJECT_DUMP.present -or
        $plans[3].before_present -ne
            [bool]$snapshots.CXX_HEADER_DUMP.present -or
        $plans[4].before_present -ne
            [bool]$snapshots.UE4SS_LOG.present) {
        throw "CGCE-OPS-PROBE-RECEIPT restore intent snapshot binding drift"
    }
    Assert-CgceRestorePlansBoundToSnapshots `
        $plans `
        $snapshots `
        $true
    if (-not $prefix.complete) {
        throw "CGCE-OPS-PROBE-RECEIPT probe restore journal is incomplete"
    }
    Assert-CgceRestoreTerminalMatrix $plans $Paths
}

function Restore-CgceInventoryProbe(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId,
    [string]$ExpectedFinalReceiptChecksum = ""
) {
    Assert-CgceRuntimePaths $Paths $RunDirectory $RunId
    if (-not (Test-Path -LiteralPath $Paths.probe_intent -PathType Leaf)) {
        Assert-CgceNoProbeResidueWithoutIntent $Paths
        return
    }
    $guardContext = [pscustomobject]@{
        paths = $Paths
        run_directory = $RunDirectory
        run_id = $RunId
    }
    Assert-CgceProbeRestoreFreshGuard `
        $Paths `
        $RunDirectory `
        $RunId
    $intentAuthority = Read-CgceProbeIntentAuthority `
        $Paths $RunDirectory $RunId
    $intent = $intentAuthority.intent
    $intentChecksum = $intentAuthority.checksum
    $snapshots = $intentAuthority.snapshots
    $authority = Read-CgceProbeStageAuthority `
        $Paths $RunId $intent $snapshots
    $finalChecksum = $authority.final_checksum
    if (-not [string]::IsNullOrEmpty($ExpectedFinalReceiptChecksum) -and
        ($null -eq $finalChecksum -or
            $finalChecksum -cne $ExpectedFinalReceiptChecksum)) {
        throw "CGCE-OPS-PROBE-RECEIPT expected final receipt mismatch"
    }
    $restoreRoot = $intent.paths.probe_restore_receipts
    $resumePrefix = $null
    if (-not (Test-Path -LiteralPath $restoreRoot)) {
        Invoke-CgceProbeRestoreMutationGuard `
            "before-restore-root" `
            $guardContext
        [IO.Directory]::CreateDirectory($restoreRoot) | Out-Null
    } elseif (@(Get-ChildItem -LiteralPath $restoreRoot -Force).Count -gt 0) {
        $resumePrefix = Read-CgceProbeRestorePrefix `
            $restoreRoot $RunId $Paths $intent.paths
        Assert-CgceProbePathObjectsEqual `
            $intent.paths $resumePrefix.intent.paths
        if ($resumePrefix.intent.stage_intent_sha256 -cne $intentChecksum -or
            $resumePrefix.intent.stage_final_sha256 -ne $finalChecksum -or
            [int]$resumePrefix.intent.stage_chain_last_sequence -ne
                [int]$authority.last_sequence -or
            $resumePrefix.intent.stage_chain_last_sha256 -cne
                $authority.last_checksum) {
            throw "CGCE-OPS-PROBE-RECEIPT restore intent stage binding drift"
        }
        $resumePlans = [object[]]@($resumePrefix.intent.plans)
        if ($resumePlans[0].before_present -ne $false -or
            $resumePlans[1].before_present -ne $true -or
            $resumePlans[2].before_present -ne
                [bool]$snapshots.OBJECT_DUMP.present -or
            $resumePlans[3].before_present -ne
                [bool]$snapshots.CXX_HEADER_DUMP.present -or
            $resumePlans[4].before_present -ne
                [bool]$snapshots.UE4SS_LOG.present) {
            throw "CGCE-OPS-PROBE-RECEIPT restore intent snapshot binding drift"
        }
        Assert-CgceRestorePlansBoundToSnapshots `
            $resumePlans $snapshots $true
        if ($resumePrefix.complete) {
            Assert-CgceInventoryProbeRestored `
                -Paths $Paths `
                -RunDirectory $RunDirectory `
                -RunId $RunId `
                -ExpectedFinalReceiptChecksum $ExpectedFinalReceiptChecksum
            return
        }
    }
    $absentFile = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $false
        length = $null; sha256 = $null; tree_sha256 = $null
    }
    $freshBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($script:CgceFreshModsText)
    $freshMods = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true
        length = [int64]$freshBytes.Length
        sha256 = (Get-CgceBytesSha256 $freshBytes)
        tree_sha256 = $null
    }
    $probeBefore = Get-CgceSnapshotState $snapshots.PROBE_SOURCE
    if ($null -eq $resumePrefix) {
        $plansList = New-Object 'Collections.Generic.List[object]'
        $planSpecs = @(
            @("PROBE", $false, $Paths.probe_staged, $null, $Paths.probe_quarantine, $probeBefore, $probeBefore, "DIRECTORY"),
            @("MODS_TXT", $true, $Paths.mods_txt, $Paths.mods_original, $Paths.mods_test, (Get-CgceSnapshotState $snapshots.MODS_TXT), $freshMods, "FILE"),
            @("OBJECT_DUMP", [bool]$snapshots.OBJECT_DUMP.present, $Paths.object_dump, $Paths.object_dump_original, $Paths.object_dump_quarantine, (Get-CgceSnapshotState $snapshots.OBJECT_DUMP), (New-CgceArtifactState $Paths.object_dump "FILE"), "FILE"),
            @("CXX_HEADER_DUMP", [bool]$snapshots.CXX_HEADER_DUMP.present, $Paths.cxx_header_dump, $Paths.cxx_header_dump_original, $Paths.cxx_header_dump_quarantine, (Get-CgceSnapshotState $snapshots.CXX_HEADER_DUMP), (New-CgceArtifactState $Paths.cxx_header_dump "DIRECTORY"), "DIRECTORY"),
            @("UE4SS_LOG", [bool]$snapshots.UE4SS_LOG.present, $Paths.ue4ss_log, $Paths.ue4ss_log_original, $Paths.ue4ss_log_quarantine, (Get-CgceSnapshotState $snapshots.UE4SS_LOG), (New-CgceArtifactState $Paths.ue4ss_log "FILE"), "FILE")
        )
        foreach ($spec in $planSpecs) {
            $active = New-CgceArtifactState $spec[2] $spec[7]
            $original = if ($null -eq $spec[3]) {
                if ($spec[7] -ceq "FILE") { $absentFile } else {
                    New-CgceArtifactState "__CGCE_MISSING__" "DIRECTORY"
                }
            } else { New-CgceArtifactState $spec[3] $spec[7] }
            $quarantine = New-CgceArtifactState $spec[4] $spec[7]
            $selected = Get-CgceRestoreSelectedCase `
                $spec[0] $spec[1] $active $original $quarantine `
                $spec[5] $spec[6] $false
            $null = $plansList.Add([pscustomobject][ordered]@{
                artifact_name = $spec[0]
                selected_case = $selected
                before_present = [bool]$spec[1]
                active_state = $active
                original_state = $original
                quarantine_state = $quarantine
            })
        }
        $plans = [object[]]$plansList.ToArray()
        Assert-CgceRestorePlansBoundToSnapshots $plans $snapshots $false
    } else {
        $plans = [object[]]@($resumePrefix.intent.plans)
    }
    $stageLast = $authority.last_checksum
    $stageSequence = $authority.last_sequence
    $restoreIntent = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_probe_restore_intent"
        run_id = $RunId
        sequence = 0
        created_at_utc = (Get-CgceRuntimeUtcNow)
        stage_intent_sha256 = $intentChecksum
        stage_final_sha256 = $finalChecksum
        stage_chain_last_sequence = $stageSequence
        stage_chain_last_sha256 = $stageLast
        paths = $intent.paths
        plans = [object[]]$plans
    }
    $restoreIntentPath = Join-Path $restoreRoot "000-probe-restore-intent.json"
    if ($null -eq $resumePrefix) {
        Invoke-CgceProbeRestoreMutationGuard `
            "before-restore-intent" `
            $guardContext
        $restoreIntentWrite = Write-CgceRuntimeJson `
            $restoreIntent $restoreIntentPath "CGCE-OPS-PROBE-RECEIPT"
        $previous = $restoreIntentWrite.checksum
    } else {
        $restoreIntentWrite = [pscustomobject]@{
            value = $resumePrefix.intent
            checksum = $resumePrefix.intent_checksum
        }
        $previous = $resumePrefix.previous_checksum
    }
    $bindings = New-Object 'Collections.Generic.List[object]'
    if ($null -ne $resumePrefix) {
        foreach ($binding in @($resumePrefix.bindings)) {
            $null = $bindings.Add($binding)
        }
    }

    $definitions = @(Get-CgceRestoreStepDefinitions $plans $Paths)
    function Add-RestoreStep($Definition) {
        $existingPath = Join-Path $restoreRoot $Definition.file_name
        if (Test-Path -LiteralPath $existingPath -PathType Leaf) {
            return
        }
        $result = Invoke-CgceRestoreStep `
            $restoreRoot $RunId $Definition.sequence $Definition.step `
            $Definition.operation $Definition.source $Definition.destination `
            $Definition.type $script:restorePrevious `
            $Definition.before $Definition.after `
            $guardContext
        $script:restorePrevious = $result.checksum
        $null = $script:restoreBindings.Add([pscustomobject][ordered]@{
            sequence = $Definition.sequence
            path = $result.path
            sha256 = $result.checksum
        })
    }
    $script:restorePrevious = $previous
    $script:restoreBindings = $bindings
    try {
        foreach ($definition in $definitions) {
            Add-RestoreStep $definition
        }
        Assert-CgceRestoreTerminalMatrix $plans $Paths
        $restored = New-Object 'Collections.Generic.List[object]'
        foreach ($entry in @(Get-CgceRestoreTerminalMatrix $plans $Paths)) {
            $null = $restored.Add([pscustomobject][ordered]@{
                artifact_name = $entry.artifact_name
                state = $entry.active_state
            })
        }
        $restoreFinal = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_probe_restore_final"
            run_id = $RunId
            sequence = 999
            restore_intent_sha256 = $restoreIntentWrite.checksum
            previous_receipt_sha256 = $script:restorePrevious
            paths = $intent.paths
            operation_receipts = [object[]]$bindings.ToArray()
            restored_states = [object[]]$restored.ToArray()
            completed_at_utc = (Get-CgceRuntimeUtcNow)
        }
        Invoke-CgceProbeCrash "restore-before-receipt-999"
        Assert-CgceProbeRestoreFreshGuard `
            $guardContext.paths `
            $guardContext.run_directory `
            $guardContext.run_id
        $null = Write-CgceRuntimeJson `
            $restoreFinal (Join-Path $restoreRoot "999-probe-restore-final.json") `
            "CGCE-OPS-PROBE-RECEIPT"
        Invoke-CgceProbeCrash "restore-after-receipt-999"
    } finally {
        $script:restorePrevious = $null
        $script:restoreBindings = $null
    }
}

function Get-CgceProcessIdentityFromRecord($Record, [string]$FallbackPath) {
    if ($null -eq $Record -or
        $null -eq $Record.PSObject.Properties["ProcessId"] -or
        $null -eq $Record.PSObject.Properties["ParentProcessId"] -or
        -not (Test-CgceRuntimeInteger `
            $Record.ProcessId 1 ([uint32]::MaxValue)) -or
        -not (Test-CgceRuntimeInteger `
            $Record.ParentProcessId 0 ([uint32]::MaxValue))) {
        throw "CGCE-OPS-MANUAL-RECOVERY process identity is incomplete"
    }
    $pathText = if ($Record.PSObject.Properties["ExecutablePath"] -ne $null -and
        -not [string]::IsNullOrWhiteSpace([string]$Record.ExecutablePath)) {
        [string]$Record.ExecutablePath
    } elseif (-not [string]::IsNullOrWhiteSpace($FallbackPath)) {
        $FallbackPath
    } else {
        throw "CGCE-OPS-MANUAL-RECOVERY process executable identity unavailable"
    }
    try {
        $path = ConvertTo-CgceCanonicalRuntimePath `
            $pathText "CGCE-OPS-MANUAL-RECOVERY"
        $fileTime = Get-CgceProcessCreationFileTime $Record
        $time = [DateTime]::FromFileTimeUtc($fileTime).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "CGCE-OPS-MANUAL-RECOVERY process identity unreadable"
    }
    return [pscustomobject][ordered]@{
        pid = [int64]$Record.ProcessId
        parent_pid = [int64]$Record.ParentProcessId
        executable_path = $path
        creation_time_utc = $time
        creation_time_filetime_utc = [int64]$fileTime
    }
}

function Get-CgceRootProcessRecord($Process, [string]$CanonicalPath) {
    $record = $null
    try {
        if ($null -ne $script:CgceTestRootProcessRecordSeam) {
            $record = & $script:CgceTestRootProcessRecordSeam `
                $Process $CanonicalPath
        } else {
            $record = Get-CimInstance -ClassName "Win32_Process" `
                -Filter ("ProcessId=" + $Process.Id) -ErrorAction Stop
        }
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY root process query failed"
    }
    if ($null -eq $record) {
        try {
            return [pscustomobject]@{
                ProcessId = [int64]$Process.Id
                ParentProcessId = [int64]0
                ExecutablePath = $CanonicalPath
                CreationTimeFileTimeUtc = ConvertTo-CgceCanonicalProcessFileTime (
                    $Process.StartTime.ToUniversalTime().ToFileTimeUtc()
                )
            }
        } catch {
            throw "CGCE-OPS-PROCESS-QUERY root process identity unavailable"
        }
    }
    return $record
}

function Get-CgceProcessRecordsSnapshot {
    try {
        if ($null -ne $script:CgceTestProcessRecordsSeam) {
            $records = @(& $script:CgceTestProcessRecordsSeam)
        } else {
            $records = @(
                Get-CimInstance `
                    -ClassName "Win32_Process" `
                    -ErrorAction Stop
            )
        }
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY descendant query failed"
    }
    foreach ($record in $records) {
        if ($null -eq $record -or
            $null -eq $record.PSObject.Properties["ProcessId"] -or
            $null -eq $record.PSObject.Properties["ParentProcessId"] -or
            -not (Test-CgceRuntimeInteger `
                $record.ProcessId 0 ([uint32]::MaxValue)) -or
            -not (Test-CgceRuntimeInteger `
                $record.ParentProcessId 0 ([uint32]::MaxValue))) {
            throw "CGCE-OPS-PROCESS-QUERY incomplete process telemetry"
        }
    }
    return [object[]]$records
}

function Get-CgceLiveObservedProcessCount(
    [object[]]$Observed,
    [object[]]$Records
) {
    $live = 0
    foreach ($identity in $Observed) {
        foreach ($record in $Records) {
            if ([int64]$record.ProcessId -eq [int64]$identity.pid) {
                $current = Get-CgceProcessIdentityFromRecord $record ""
                if ((Test-CgceRuntimePathEqual `
                        $current.executable_path `
                        $identity.executable_path) -and
                    [int64]$current.creation_time_filetime_utc -eq
                        [int64]$identity.creation_time_filetime_utc) {
                    $live += 1
                }
            }
        }
    }
    return $live
}

function Assert-CgceObservedProcessesTerminated(
    [object[]]$Observed,
    [object[]]$Records
) {
    if ((Get-CgceLiveObservedProcessCount `
            -Observed $Observed `
            -Records $Records) -ne 0) {
        throw "CGCE-OPS-PROCESS-TIMEOUT observed process still active"
    }
}

function Get-CgceRemainingProcessMilliseconds(
    $Stopwatch,
    [int]$TimeoutSeconds
) {
    $limit = [int64]$TimeoutSeconds * 1000
    $elapsed = [int64][Math]::Ceiling($Stopwatch.Elapsed.TotalMilliseconds)
    $remaining = $limit - $elapsed
    if ($remaining -le 0) {
        return 0
    }
    if ($remaining -gt [int]::MaxValue) {
        return [int]::MaxValue
    }
    return [int]$remaining
}

function Assert-CgceProcessCompletedWithinDeadline(
    $Stopwatch,
    [int]$TimeoutSeconds,
    [DateTime]$ControlDeadlineUtc
) {
    $limit = [int64]$TimeoutSeconds * 1000
    if ($Stopwatch.Elapsed.TotalMilliseconds -gt [double]$limit) {
        throw "CGCE-OPS-PROCESS-TIMEOUT child exited after timeout"
    }
    if ([DateTime]::UtcNow -gt $ControlDeadlineUtc) {
        throw "CGCE-OPS-CONTROL-EXPIRED child exited after control validity"
    }
}

function ConvertTo-CgceControlDeadline($Value) {
    try {
        if ($Value -is [DateTime]) {
            if (([DateTime]$Value).Kind -ne [DateTimeKind]::Utc) {
                throw "control deadline must already be UTC"
            }
            $utc = [DateTime]$Value
        } elseif ($Value -is [string]) {
            $utc = ConvertFrom-CgceRuntimeUtcTimestamp `
                -Value $Value `
                -Code "CGCE-OPS-CONTROL-EXPIRED"
        } else {
            throw "invalid control deadline type"
        }
        $text = $utc.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        if (-not (Test-CgceRuntimeUtcTimestamp $text)) {
            throw "invalid normalized control deadline"
        }
    } catch {
        throw "CGCE-OPS-CONTROL-EXPIRED invalid control validity deadline"
    }
    return [pscustomobject]@{
        value = $utc
        text = $text
    }
}

function Invoke-CgceChildProcess(
    [string]$Executable,
    [string]$ExpectedExecutableChecksum,
    [string[]]$AllowedExecutablePaths,
    [string[]]$Arguments,
    [string]$ReceiptRoot,
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [scriptblock]$PreLaunchValidation,
    [Parameter(Mandatory = $true)]
    $ControlValidUntilUtc
) {
    Assert-CgceServerArguments $Arguments
    $nativeCommandLine = if ($Arguments.Count -eq 0) {
        [string]::Empty
    } else {
        ConvertTo-CgceWindowsCommandLine -Arguments $Arguments
    }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 86400) {
        throw "CGCE-OPS-PROCESS-TIMEOUT invalid timeout"
    }
    $controlDeadline = ConvertTo-CgceControlDeadline $ControlValidUntilUtc
    try {
        $requiredDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    } catch {
        throw "CGCE-OPS-CONTROL-EXPIRED invalid launch deadline"
    }
    if ($requiredDeadline -gt $controlDeadline.value) {
        throw "CGCE-OPS-CONTROL-EXPIRED timeout exceeds control validity"
    }
    $canonicalExecutable = ConvertTo-CgceCanonicalRuntimePath `
        $Executable "CGCE-OPS-PROCESS-RECEIPT"
    $encodedExecutable = ConvertTo-CgceWindowsCommandLineArgument `
        -Argument $canonicalExecutable
    $nativeCommandLength = $encodedExecutable.Length
    if ($nativeCommandLine.Length -gt 0) {
        $nativeCommandLength += 1 + $nativeCommandLine.Length
    }
    if ($nativeCommandLength -gt 32766) {
        throw "CGCE-OPS-ARGUMENT native command line exceeds Windows limit"
    }
    $paths = @(ConvertTo-CgceRuntimeExecutablePaths $AllowedExecutablePaths)
    if (-not (@($paths | Where-Object {
                Test-CgceRuntimePathEqual $_ $canonicalExecutable
            }).Count -eq 1)) {
        throw "CGCE-OPS-PROCESS-UNLISTED executable absent from allowlist"
    }
    Assert-CgceNoReparseInPath -Path $canonicalExecutable
    if (-not (Test-Path -LiteralPath $canonicalExecutable -PathType Leaf) -or
        -not (Test-CgceRuntimeChecksum $ExpectedExecutableChecksum) -or
        (Get-CgceSha256 $canonicalExecutable) -cne $ExpectedExecutableChecksum) {
        throw "CGCE-OPS-CHECKSUM executable checksum mismatch"
    }
    $runId = Get-CgceProcessRunId $ReceiptRoot
    Assert-CgceProcessReceiptDirectory $ReceiptRoot
    if (@(Get-ChildItem -LiteralPath $ReceiptRoot -Force).Count -ne 0) {
        throw "CGCE-OPS-PROCESS-RECEIPT process launch replay blocked"
    }
    $working = Split-Path -Parent $canonicalExecutable
    $createdAt = Get-CgceRuntimeUtcNow
    $launch = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_process_launch"
        run_id = $runId
        sequence = 0
        created_at_utc = $createdAt
        executable_path = $canonicalExecutable
        executable_sha256 = $ExpectedExecutableChecksum
        working_directory = $working
        allowed_executable_path_count = $paths.Count
        allowed_executable_paths_sha256 = (Get-CgceFramedStringArraySha256 `
            "CGCE-PATHS-1" $paths)
        argument_count = $Arguments.Count
        arguments_sha256 = (Get-CgceFramedStringArraySha256 `
            "CGCE-ARGS-1" $Arguments)
        timeout_seconds = $TimeoutSeconds
        control_valid_until_utc = $controlDeadline.text
        previous_receipt_sha256 = $null
    }
    $launchPath = Join-Path $ReceiptRoot "000-launch.json"
    $launchWrite = Write-CgceRuntimeJson `
        $launch $launchPath "CGCE-OPS-PROCESS-RECEIPT"
    if ($null -ne $script:CgceTestLaunchReceiptSeam) {
        $null = & $script:CgceTestLaunchReceiptSeam $launchPath
    }
    $launchAuthority = Read-CgceLaunchReceipt `
        -Path $launchPath `
        -RunId $runId
    Assert-CgceLaunchReceiptBinding `
        -Actual $launchAuthority `
        -Expected $launch `
        -CanonicalPaths $paths `
        -Arguments $Arguments
    $launchDeadlineUtc = (
        ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $launchAuthority.created_at_utc `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
    ).AddSeconds($TimeoutSeconds)
    if ((Get-CgceSha256 -Path $launchPath) -cne $launchWrite.checksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT launch receipt checksum drift"
    }
    if ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds) -gt
        $controlDeadline.value) {
        throw "CGCE-OPS-CONTROL-EXPIRED launch deadline no longer authorized"
    }
    Assert-CgceNoReparseInPath -Path $canonicalExecutable
    if (-not (Test-Path -LiteralPath $canonicalExecutable -PathType Leaf) -or
        (Get-CgceSha256 -Path $canonicalExecutable) -cne
            $ExpectedExecutableChecksum) {
        throw "CGCE-OPS-CHECKSUM executable drift immediately before launch"
    }
    if ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds) -gt
        $controlDeadline.value) {
        throw "CGCE-OPS-CONTROL-EXPIRED pre-launch authority deadline expired"
    }
    if ([DateTime]::UtcNow -gt $launchDeadlineUtc) {
        throw "CGCE-OPS-PROCESS-TIMEOUT launch intent expired before authority"
    }
    $null = & $PreLaunchValidation $launchWrite.checksum
    if ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds) -gt
        $controlDeadline.value) {
        throw "CGCE-OPS-CONTROL-EXPIRED pre-launch authority expired"
    }
    if ([DateTime]::UtcNow -gt $launchDeadlineUtc) {
        throw "CGCE-OPS-PROCESS-TIMEOUT launch intent expired"
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $startedAt = Get-CgceRuntimeUtcNow
    $startParameters = @{
        FilePath = $canonicalExecutable
        WorkingDirectory = $working
        PassThru = $true
    }
    if ($nativeCommandLine.Length -gt 0) {
        $startParameters["ArgumentList"] = [string[]]@($nativeCommandLine)
    }
    try {
        $process = Start-Process @startParameters
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY child launch failed"
    }
    Invoke-CgceProcessCrash "after-process-start"
    try {
        $immediateRootRecord = [pscustomobject]@{
            ProcessId = [int64]$process.Id
            ParentProcessId = [int64]0
            ExecutablePath = $canonicalExecutable
            CreationTimeFileTimeUtc = ConvertTo-CgceCanonicalProcessFileTime (
                $process.StartTime.ToUniversalTime().ToFileTimeUtc()
            )
        }
        $immediateRootIdentity = Get-CgceProcessIdentityFromRecord `
            $immediateRootRecord `
            $canonicalExecutable
    } catch {
        Write-CgceManualRecoveryBarrier `
            -ReceiptRoot $ReceiptRoot `
            -RunId $runId `
            -ProcessId ([int64]$process.Id) `
            -ParentPid 0 `
            -PreviousChecksum $launchWrite.checksum `
            -PidReceipts @()
        throw "CGCE-OPS-MANUAL-RECOVERY immediate root identity unavailable"
    }
    $observed = New-Object 'Collections.Generic.List[object]'
    $bindings = New-Object 'Collections.Generic.List[object]'
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $previous = $launchWrite.checksum

    function Add-ProcessIdentity($Identity) {
        if ($null -eq $Identity -or
            -not (Test-CgceRuntimeInteger `
                $Identity.pid 1 ([uint32]::MaxValue)) -or
            -not (Test-CgceRuntimeInteger `
                $Identity.parent_pid 0 ([uint32]::MaxValue)) -or
            -not (Test-CgceRuntimeInteger `
                $Identity.creation_time_filetime_utc 1 ([int64]::MaxValue)) -or
            -not (Test-CgceRuntimeUtcTimestamp $Identity.creation_time_utc) -or
            [string]::IsNullOrWhiteSpace([string]$Identity.executable_path)) {
            throw "CGCE-OPS-MANUAL-RECOVERY process identity unreadable"
        }
        $identityPath = ConvertTo-CgceCanonicalRuntimePath `
            $Identity.executable_path "CGCE-OPS-MANUAL-RECOVERY"
        $key = "$($Identity.pid)|$identityPath|$($Identity.creation_time_filetime_utc)"
        if (-not $script:processSeen.Add($key)) { return }
        if (@($script:processObserved.ToArray() | Where-Object {
                    [int64]$_.pid -eq [int64]$Identity.pid
                }).Count -ne 0) {
            Write-CgceManualRecoveryBarrier `
                -ReceiptRoot $script:processReceiptRoot `
                -RunId $script:processRunId `
                -ProcessId ([int64]$Identity.pid) `
                -ParentPid ([int64]$Identity.parent_pid) `
                -PreviousChecksum $script:processPrevious `
                -PidReceipts ([object[]]$script:processObserved.ToArray())
            throw "CGCE-OPS-MANUAL-RECOVERY duplicate PID identity"
        }
        if ($script:processObserved.Count -ge 998) {
            Write-CgceManualRecoveryBarrier `
                -ReceiptRoot $script:processReceiptRoot `
                -RunId $script:processRunId `
                -ProcessId ([int64]$Identity.pid) `
                -ParentPid ([int64]$Identity.parent_pid) `
                -PreviousChecksum $script:processPrevious `
                -PidReceipts ([object[]]$script:processObserved.ToArray())
            throw "CGCE-OPS-MANUAL-RECOVERY PID receipt bound exceeded"
        }
        $sequence = $script:processObserved.Count + 1
        if ($sequence -eq 1) {
            if ([int64]$Identity.pid -ne [int64]$script:processRootPid -or
                [int64]$Identity.parent_pid -ne 0) {
                throw "CGCE-OPS-PROCESS-RECEIPT root PID binding drift"
            }
        } else {
            $parentMatches = @(
                $script:processObserved.ToArray() |
                    Where-Object {
                        [int64]$_.pid -eq [int64]$Identity.parent_pid
                    }
            )
            if ($parentMatches.Count -ne 1) {
                throw "CGCE-OPS-PROCESS-RECEIPT descendant parent not unique"
            }
            if ([int64]$Identity.creation_time_filetime_utc -lt
                [int64]$parentMatches[0].creation_time_filetime_utc) {
                throw "CGCE-OPS-PROCESS-RECEIPT descendant predates parent"
            }
        }
        $receipt = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $script:processRunId
            sequence = $sequence
            pid = [int64]$Identity.pid
            parent_pid = [int64]$Identity.parent_pid
            executable_path = $identityPath
            creation_time_utc = $Identity.creation_time_utc
            creation_time_filetime_utc = [int64]$Identity.creation_time_filetime_utc
            observed_at_utc = (Get-CgceRuntimeUtcNow)
            previous_receipt_sha256 = $script:processPrevious
        }
        $path = Join-Path $script:processReceiptRoot (
            $sequence.ToString("000") + "-pid.json"
        )
        $written = Write-CgceRuntimeJson `
            $receipt $path "CGCE-OPS-PROCESS-RECEIPT"
        $readBack = Read-CgcePidReceipt `
            -Path $path `
            -RunId $script:processRunId `
            -ExpectedSequence $sequence `
            -PreviousChecksum $script:processPrevious
        if ([int64]$readBack.pid -ne [int64]$receipt.pid -or
            [int64]$readBack.parent_pid -ne [int64]$receipt.parent_pid -or
            -not (Test-CgceRuntimePathEqual `
                (ConvertTo-CgceCanonicalRuntimePath `
                    $readBack.executable_path `
                    "CGCE-OPS-PROCESS-RECEIPT") `
                $identityPath) -or
            $readBack.creation_time_utc -cne $receipt.creation_time_utc -or
            [int64]$readBack.creation_time_filetime_utc -ne
                [int64]$receipt.creation_time_filetime_utc -or
            (Get-CgceSha256 -Path $path) -cne $written.checksum) {
            throw "CGCE-OPS-PROCESS-RECEIPT PID receipt semantic drift"
        }
        $null = $script:processObserved.Add($readBack)
        $null = $script:processBindings.Add([pscustomobject][ordered]@{
            sequence = $sequence; path = $path; sha256 = $written.checksum
        })
        $script:processPrevious = $written.checksum
        Invoke-CgceProcessCrash ("after-pid-" + $sequence)
        if ($sequence -eq 1 -and
            -not (Test-CgceRuntimePathEqual `
                $identityPath $script:processRootExecutable)) {
            throw "CGCE-OPS-PROCESS-RECEIPT root executable binding drift"
        }
        $isAllowed = @($script:processAllowed | Where-Object {
            Test-CgceRuntimePathEqual $_ $identityPath
        }).Count -eq 1
        if (-not $isAllowed) {
            throw "CGCE-OPS-PROCESS-UNLISTED observed descendant not allowlisted"
        }
    }

    function Add-ObservedDescendants([object[]]$Records) {
        $added = $true
        while ($added) {
            $added = $false
            foreach ($record in $Records) {
                $parentMatches = @(
                    $script:processObserved.ToArray() |
                        Where-Object {
                            [int64]$_.pid -eq
                                [int64]$record.ParentProcessId
                        }
                )
                if ($parentMatches.Count -gt 1) {
                    throw "CGCE-OPS-PROCESS-RECEIPT ambiguous parent PID"
                }
                if ($parentMatches.Count -eq 1) {
                    try {
                        $identity = Get-CgceProcessIdentityFromRecord $record ""
                    } catch {
                        Write-CgceManualRecoveryBarrier `
                            -ReceiptRoot $script:processReceiptRoot `
                            -RunId $script:processRunId `
                            -ProcessId ([int64]$record.ProcessId) `
                            -ParentPid ([int64]$record.ParentProcessId) `
                            -PreviousChecksum $script:processPrevious `
                            -PidReceipts ([object[]]$script:processObserved.ToArray())
                        throw "CGCE-OPS-MANUAL-RECOVERY process identity unreadable"
                    }
                    if ([int64]$identity.creation_time_filetime_utc -lt
                        [int64]$parentMatches[0].creation_time_filetime_utc) {
                        continue
                    }
                    $before = $script:processObserved.Count
                    Add-ProcessIdentity $identity
                    if ($script:processObserved.Count -gt $before) {
                        $added = $true
                    }
                }
            }
        }
    }
    $script:processObserved = $observed
    $script:processBindings = $bindings
    $script:processSeen = $seen
    $script:processAllowed = $paths
    $script:processRunId = $runId
    $script:processReceiptRoot = $ReceiptRoot
    $script:processPrevious = $previous
    $script:processRootPid = [int64]$process.Id
    $script:processRootExecutable = $canonicalExecutable
    try {
        Add-ProcessIdentity $immediateRootIdentity
        $rootRecord = Get-CgceRootProcessRecord `
            -Process $process `
            -CanonicalPath $canonicalExecutable
        $verifiedRootIdentity = Get-CgceProcessIdentityFromRecord `
            $rootRecord `
            $canonicalExecutable
        if ([int64]$verifiedRootIdentity.pid -ne
                [int64]$immediateRootIdentity.pid -or
            -not (Test-CgceRuntimePathEqual `
                $verifiedRootIdentity.executable_path `
                $immediateRootIdentity.executable_path) -or
            [int64]$verifiedRootIdentity.creation_time_filetime_utc -ne
                [int64]$immediateRootIdentity.creation_time_filetime_utc) {
            throw "CGCE-OPS-MANUAL-RECOVERY root identity verification drift"
        }
        while ($true) {
            $records = @(Get-CgceProcessRecordsSnapshot)
            Add-ObservedDescendants -Records $records
            $live = Get-CgceLiveObservedProcessCount `
                -Observed ([object[]]$observed.ToArray()) `
                -Records $records
            $remainingMilliseconds = Get-CgceRemainingProcessMilliseconds `
                -Stopwatch $stopwatch `
                -TimeoutSeconds $TimeoutSeconds
            $controlRemainingMilliseconds = [int64][Math]::Floor(
                ($controlDeadline.value - [DateTime]::UtcNow).TotalMilliseconds
            )
            if ($controlRemainingMilliseconds -le 0) {
                $remainingMilliseconds = 0
            } elseif ($controlRemainingMilliseconds -lt
                $remainingMilliseconds) {
                $remainingMilliseconds = [int]$controlRemainingMilliseconds
            }
            $launchRemainingMilliseconds = [int64][Math]::Floor(
                ($launchDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
            )
            if ($launchRemainingMilliseconds -le 0) {
                $remainingMilliseconds = 0
            } elseif ($launchRemainingMilliseconds -lt
                $remainingMilliseconds) {
                $remainingMilliseconds = [int]$launchRemainingMilliseconds
            }
            [int]$waitSliceMilliseconds = [Math]::Min(
                [int]100,
                [int]$remainingMilliseconds
            )
            $rootExited = $process.WaitForExit(
                [int]$waitSliceMilliseconds
            )
            if ($rootExited -and $live -eq 0) {
                Assert-CgceProcessCompletedWithinDeadline `
                    -Stopwatch $stopwatch `
                    -TimeoutSeconds $TimeoutSeconds `
                    -ControlDeadlineUtc $controlDeadline.value
                if ([DateTime]::UtcNow -gt $launchDeadlineUtc) {
                    throw "CGCE-OPS-PROCESS-TIMEOUT child exited after launch intent"
                }
                $finalRecords = @(Get-CgceProcessRecordsSnapshot)
                Add-ObservedDescendants -Records $finalRecords
                $finalLive = Get-CgceLiveObservedProcessCount `
                    -Observed ([object[]]$observed.ToArray()) `
                    -Records $finalRecords
                if ($finalLive -ne 0) {
                    continue
                }
                Assert-CgceObservedProcessesTerminated `
                    -Observed ([object[]]$observed.ToArray()) `
                    -Records $finalRecords
                break
            }
            if ($remainingMilliseconds -le 0) {
                throw "CGCE-OPS-PROCESS-TIMEOUT child process still active"
            }
            if ($rootExited) {
                Start-Sleep -Milliseconds $waitSliceMilliseconds
            }
        }
        if (-not $process.WaitForExit(0)) {
            throw "CGCE-OPS-PROCESS-TIMEOUT root process still active"
        }
        Assert-CgceProcessCompletedWithinDeadline `
            -Stopwatch $stopwatch `
            -TimeoutSeconds $TimeoutSeconds `
            -ControlDeadlineUtc $controlDeadline.value
        if ([DateTime]::UtcNow -gt $launchDeadlineUtc) {
            throw "CGCE-OPS-PROCESS-TIMEOUT final sweep exceeded launch intent"
        }
        try {
            $exitCode = [int]$process.ExitCode
            $exitAt = Get-CgceRuntimeUtcNow
        } catch {
            throw "CGCE-OPS-MANUAL-RECOVERY root exit identity unavailable"
        }
        Assert-CgceProcessCompletedWithinDeadline `
            -Stopwatch $stopwatch `
            -TimeoutSeconds $TimeoutSeconds `
            -ControlDeadlineUtc $controlDeadline.value
        $exitAtValue = ConvertFrom-CgceRuntimeUtcTimestamp `
            -Value $exitAt `
            -Code "CGCE-OPS-PROCESS-RECEIPT"
        if ($exitAtValue -gt $launchDeadlineUtc) {
            throw "CGCE-OPS-PROCESS-TIMEOUT result exceeded launch intent"
        }
        $observedResult = @(
            foreach ($receipt in @($observed)) {
                [pscustomobject][ordered]@{
                    sequence = $receipt.sequence
                    pid = $receipt.pid
                    parent_pid = $receipt.parent_pid
                    executable_path = $receipt.executable_path
                    creation_time_utc = $receipt.creation_time_utc
                    creation_time_filetime_utc = $receipt.creation_time_filetime_utc
                }
            }
        )
        $result = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_result"
            run_id = $runId
            sequence = 999
            launch_receipt_sha256 = $launchWrite.checksum
            previous_receipt_sha256 = $script:processPrevious
            started_at_utc = $startedAt
            exit_at_utc = $exitAt
            exit_code = $exitCode
            observed_processes = [object[]]$observedResult
            pid_receipts = [object[]]$bindings.ToArray()
        }
        Invoke-CgceProcessCrash "before-result"
        $resultPath = Join-Path $ReceiptRoot "999-result.json"
        $resultWrite = Write-CgceRuntimeJson `
            $result $resultPath "CGCE-OPS-PROCESS-RECEIPT"
        $null = Read-CgceProcessReceiptChain `
            -ReceiptRoot $ReceiptRoot `
            -CanonicalPaths $paths
        return [pscustomobject][ordered]@{
            result = $resultWrite.value
            launch_receipt_checksum = $launchWrite.checksum
            result_receipt_checksum = $resultWrite.checksum
        }
    } finally {
        $script:processObserved = $null
        $script:processBindings = $null
        $script:processSeen = $null
        $script:processAllowed = $null
        $script:processRunId = $null
        $script:processReceiptRoot = $null
        $script:processPrevious = $null
        $script:processRootPid = $null
        $script:processRootExecutable = $null
        if ($null -ne $stopwatch) {
            $stopwatch.Stop()
        }
    }
}

Export-ModuleMember -Function @(
    "Assert-CgceNoServerActivity",
    "Assert-CgceNoForeignRunArtifacts",
    "Assert-CgceInventoryProbeRestored",
    "Assert-CgceInventoryProbeStaged",
    "Assert-CgceServerArguments",
    "Enable-CgceInventoryProbe",
    "Restore-CgceInventoryProbe",
    "Invoke-CgceChildProcess"
)
