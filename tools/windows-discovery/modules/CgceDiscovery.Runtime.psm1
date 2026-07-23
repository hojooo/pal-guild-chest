Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$contractModule = Join-Path $PSScriptRoot "CgceDiscovery.Contract.psm1"
Import-Module $contractModule | Out-Null
$filesModule = Join-Path $PSScriptRoot "CgceDiscovery.Files.psm1"
Import-Module $filesModule | Out-Null

$script:CgceTestProbeCrashSeam = $null
$script:CgceTestActivitySnapshotSeam = $null
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
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$'
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
    if ($null -eq $Arguments) {
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
            $argument -cnotmatch '^[-A-Za-z0-9_=.:/\\]+$') {
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

function ConvertTo-CgceRuntimeExecutablePaths([string[]]$ExecutablePaths) {
    if ($null -eq $ExecutablePaths -or $ExecutablePaths.Count -eq 0) {
        throw "CGCE-OPS-PROCESS-QUERY exhaustive executable paths required"
    }
    $result = New-Object 'Collections.Generic.List[string]'
    $seen = New-Object 'Collections.Generic.HashSet[string]' `
        -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $ExecutablePaths) {
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

function Get-CgceProcessCreationFileTime($ProcessRecord) {
    if ($ProcessRecord.PSObject.Properties["CreationTimeFileTimeUtc"] -ne $null) {
        return [int64]$ProcessRecord.CreationTimeFileTimeUtc
    }
    if ($ProcessRecord.PSObject.Properties["CreationDate"] -eq $null -or
        $null -eq $ProcessRecord.CreationDate) {
        throw "CGCE-OPS-PROCESS-QUERY process creation time unavailable"
    }
    try {
        if ($ProcessRecord.CreationDate -is [DateTime]) {
            return ([DateTime]$ProcessRecord.CreationDate).ToUniversalTime().ToFileTimeUtc()
        }
        return [Management.ManagementDateTimeConverter]::ToDateTime(
            [string]$ProcessRecord.CreationDate
        ).ToUniversalTime().ToFileTimeUtc()
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
            $child.Name -cnotmatch '^(?:000-launch|[0-9]{3}-pid|999-result)\.json$') {
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
        "previous_receipt_sha256"
    ) "CGCE-OPS-PROCESS-RECEIPT"
    if ($value.schema_version -cne "1.0" -or
        $value.kind -cne "cgce_windows_discovery_process_launch" -or
        $value.run_id -cne $RunId -or [int]$value.sequence -ne 0 -or
        $null -ne $value.previous_receipt_sha256 -or
        -not (Test-CgceRuntimeChecksum $value.executable_sha256) -or
        -not (Test-CgceRuntimeChecksum $value.allowed_executable_paths_sha256) -or
        -not (Test-CgceRuntimeChecksum $value.arguments_sha256)) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid launch receipt fields"
    }
    return $value
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
        [int]$value.sequence -ne $ExpectedSequence -or
        $value.previous_receipt_sha256 -cne $PreviousChecksum) {
        throw "CGCE-OPS-PROCESS-RECEIPT invalid PID receipt chain"
    }
    return $value
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
    $previous = Get-CgceSha256 -Path $launchPath
    $pidReceipts = New-Object 'Collections.Generic.List[object]'
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
        $null = $pidReceipts.Add($receipt)
        $previous = Get-CgceSha256 -Path $path
    }
    $pidFiles = @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter "*-pid.json")
    if ($pidFiles.Count -ne $pidReceipts.Count) {
        throw "CGCE-OPS-PROCESS-RECEIPT PID receipt sequence gap"
    }
    return [pscustomobject]@{
        run_id = $runId
        launch = $launch
        launch_checksum = (Get-CgceSha256 -Path $launchPath)
        pid_receipts = [object[]]$pidReceipts.ToArray()
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
        $chain = Read-CgceProcessReceiptChain `
            -ReceiptRoot $ReceiptRoot `
            -CanonicalPaths $paths
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
        $pid = if ($process.PSObject.Properties["ProcessId"] -ne $null) {
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
                if ([int64]$receipt.pid -eq $pid) {
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
            if ($line -match '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?$') {
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
    foreach ($key in @(
        "artifact_type", "present", "length", "sha256", "tree_sha256"
    )) {
        if ($Left.$key -ne $Right.$key) { return $false }
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
    $entries = if ($state.present -and $Type -ceq "DIRECTORY") {
        [object[]]@(Get-CgceTreeInventory -Root $Path)
    } else { $null }
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
    [string]$Previous
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
        if ($line -match '^\s*CGCEDiscoveryInventory\s*:\s*1(?:\s*(?:;.*)?)?$') {
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

function Read-CgceProbeSnapshotMap($Intent) {
    $map = @{}
    foreach ($binding in @($Intent.snapshots)) {
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
            $snapshot.artifact_name -cne $binding.artifact_name) {
            throw "CGCE-OPS-PROBE-RECEIPT snapshot identity drift"
        }
        $map[$binding.artifact_name] = $snapshot
    }
    if ([string]::Join(",", @($map.Keys | Sort-Object)) -cne
        "CXX_HEADER_DUMP,MODS_TXT,OBJECT_DUMP,PROBE_SOURCE,UE4SS_LOG") {
        throw "CGCE-OPS-PROBE-RECEIPT snapshot set drift"
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
        }
    }
}

function Read-CgceProbeStageAuthority($Paths, [string]$RunId) {
    $specs = @(
        @(10, "010-preserve-mods.json", "PRESERVE_MODS"),
        @(20, "020-create-test-mods.json", "CREATE_TEST_MODS"),
        @(30, "030-preserve-object-dump.json", "PRESERVE_OBJECT_DUMP"),
        @(40, "040-preserve-cxx-header-dump.json", "PRESERVE_CXX_HEADER_DUMP"),
        @(50, "050-preserve-ue4ss-log.json", "PRESERVE_UE4SS_LOG"),
        @(60, "060-stage-probe.json", "STAGE_PROBE")
    )
    $allowed = @(
        "000-probe-intent.json",
        "999-probe-final.json",
        "restore"
    ) + @($specs | ForEach-Object { $_[1] })
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
        $path = Join-Path $Paths.probe_receipts $spec[1]
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
            [int]$receipt.sequence -ne [int]$spec[0] -or
            $receipt.step -cne $spec[2] -or
            $receipt.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT staging receipt chain drift"
        }
        $previous = Get-CgceSha256 $path
        $lastSequence = [int]$spec[0]
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
        if ($final.kind -cne "cgce_windows_discovery_probe_final" -or
            $final.run_id -cne $RunId -or [int]$final.sequence -ne 999 -or
            $final.intent_sha256 -cne $intentChecksum -or
            $final.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT final receipt chain drift"
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

function Get-CgceRestoreSelectedCase(
    [string]$Name,
    [bool]$BeforePresent,
    $Active,
    $Original,
    $Quarantine,
    $Before,
    $Test
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
        if ($aB -and $oN -and $qN) { return "ORIGINAL_UNCHANGED" }
        if ($aN -and $oB -and $qN) { return "ORIGINAL_PRESERVED_NO_TEST" }
        if ($aT -and $oB -and $qN) { return "TEST_ACTIVE_AND_ORIGINAL_PRESERVED" }
        if ($aN -and $oB -and $qT) { return "TEST_QUARANTINED_AND_ORIGINAL_PRESERVED" }
    } elseif (-not $BeforePresent) {
        if ($aN -and $oN -and $qN) { return "BEFORE_ABSENT_NO_TEST" }
        if ($aT -and $oN -and $qN) { return "BEFORE_ABSENT_TEST_ACTIVE" }
        if ($aN -and $oN -and $qT) { return "BEFORE_ABSENT_TEST_QUARANTINED" }
    } else {
        if ($aB -and $oN -and $qN) { return "BEFORE_PRESENT_ALREADY_RESTORED" }
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
            Assert-CgceRuntimeExactKeys $state @(
                "artifact_type", "present", "length", "sha256", "tree_sha256"
            ) "CGCE-OPS-PROBE-RECEIPT"
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
        $restoreOperation = if ($plan.selected_case -like "BEFORE_PRESENT_*" -and
            $plan.selected_case -notlike "*ALREADY_RESTORED") {
            if ($output[7] -ceq "FILE") { "MOVE_FILE" } else { "MOVE_DIRECTORY" }
        } elseif ($plan.selected_case -like "*ALREADY_RESTORED") {
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
    $ExpectedAfter
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
        -Previous $Previous
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
    $Paths
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
    if ($intent.kind -cne "cgce_windows_discovery_probe_restore_intent" -or
        $intent.run_id -cne $RunId -or [int]$intent.sequence -ne 0) {
        throw "CGCE-OPS-PROBE-RECEIPT restore intent identity drift"
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
        if ($receipt.kind -cne "cgce_windows_discovery_probe_restore_operation" -or
            $receipt.run_id -cne $RunId -or
            [int]$receipt.sequence -ne [int]$definition.sequence -or
            $receipt.step -cne $definition.step -or
            $receipt.operation -cne $definition.operation -or
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
        if ($final.kind -cne "cgce_windows_discovery_probe_restore_final" -or
            $final.run_id -cne $RunId -or [int]$final.sequence -ne 999 -or
            $final.restore_intent_sha256 -cne (Get-CgceSha256 $intentPath) -or
            $final.previous_receipt_sha256 -cne $previous) {
            throw "CGCE-OPS-PROBE-RECEIPT restore final chain drift"
        }
    }
    return [pscustomobject]@{
        intent = $intent
        intent_checksum = (Get-CgceSha256 $intentPath)
        previous_checksum = $previous
        bindings = [object[]]$bindings.ToArray()
        definitions = [object[]]$definitions
        complete = $complete
    }
}

function Restore-CgceInventoryProbe(
    $Paths,
    [string]$RunDirectory,
    [string]$RunId,
    [string]$ExpectedFinalReceiptChecksum = ""
) {
    Assert-CgceRuntimePaths $Paths $RunDirectory $RunId
    if (-not (Test-Path -LiteralPath $Paths.probe_intent -PathType Leaf)) {
        return
    }
    try { $intent = Read-CgceJsonObject $Paths.probe_intent } catch {
        throw "CGCE-OPS-PROBE-RECEIPT invalid probe intent"
    }
    if ($intent.run_id -cne $RunId -or
        $intent.kind -cne "cgce_windows_discovery_probe_intent") {
        throw "CGCE-OPS-PROBE-RECEIPT probe intent identity drift"
    }
    $intentChecksum = Get-CgceSha256 $Paths.probe_intent
    $authority = Read-CgceProbeStageAuthority $Paths $RunId
    $finalChecksum = $authority.final_checksum
    if (-not [string]::IsNullOrEmpty($ExpectedFinalReceiptChecksum) -and
        ($null -eq $finalChecksum -or
            $finalChecksum -cne $ExpectedFinalReceiptChecksum)) {
        throw "CGCE-OPS-PROBE-RECEIPT expected final receipt mismatch"
    }
    $snapshots = Read-CgceProbeSnapshotMap $intent
    $restoreRoot = $intent.paths.probe_restore_receipts
    $resumePrefix = $null
    if (-not (Test-Path -LiteralPath $restoreRoot)) {
        [IO.Directory]::CreateDirectory($restoreRoot) | Out-Null
    } elseif (@(Get-ChildItem -LiteralPath $restoreRoot -Force).Count -gt 0) {
        $resumePrefix = Read-CgceProbeRestorePrefix $restoreRoot $RunId $Paths
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
        if ($resumePrefix.complete) {
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
                $spec[0] $spec[1] $active $original $quarantine $spec[5] $spec[6]
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
            $Definition.before $Definition.after
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
        $restored = New-Object 'Collections.Generic.List[object]'
        foreach ($spec in @(
            @("PROBE", $Paths.probe_staged, "DIRECTORY"),
            @("MODS_TXT", $Paths.mods_txt, "FILE"),
            @("OBJECT_DUMP", $Paths.object_dump, "FILE"),
            @("CXX_HEADER_DUMP", $Paths.cxx_header_dump, "DIRECTORY"),
            @("UE4SS_LOG", $Paths.ue4ss_log, "FILE")
        )) {
            $null = $restored.Add([pscustomobject][ordered]@{
                artifact_name = $spec[0]
                state = (New-CgceArtifactState $spec[1] $spec[2])
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
    $path = if ($Record.PSObject.Properties["ExecutablePath"] -ne $null -and
        -not [string]::IsNullOrWhiteSpace([string]$Record.ExecutablePath)) {
        ConvertTo-CgceCanonicalRuntimePath `
            ([string]$Record.ExecutablePath) "CGCE-OPS-PROCESS-QUERY"
    } else { $FallbackPath }
    $fileTime = Get-CgceProcessCreationFileTime $Record
    $time = [DateTime]::FromFileTimeUtc($fileTime).ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
    return [pscustomobject]@{
        pid = [int64]$Record.ProcessId
        parent_pid = if ($Record.PSObject.Properties["ParentProcessId"] -ne $null) {
            [int64]$Record.ParentProcessId
        } else { [int64]0 }
        executable_path = $path
        creation_time_utc = $time
        creation_time_filetime_utc = [int64]$fileTime
    }
}

function Invoke-CgceChildProcess(
    [string]$Executable,
    [string]$ExpectedExecutableChecksum,
    [string[]]$AllowedExecutablePaths,
    [string[]]$Arguments,
    [string]$ReceiptRoot,
    [int]$TimeoutSeconds
) {
    Assert-CgceServerArguments $Arguments
    if ($TimeoutSeconds -lt 1) {
        throw "CGCE-OPS-PROCESS-TIMEOUT invalid timeout"
    }
    $canonicalExecutable = ConvertTo-CgceCanonicalRuntimePath `
        $Executable "CGCE-OPS-PROCESS-RECEIPT"
    $paths = @(ConvertTo-CgceRuntimeExecutablePaths $AllowedExecutablePaths)
    if (-not (@($paths | Where-Object {
                Test-CgceRuntimePathEqual $_ $canonicalExecutable
            }).Count -eq 1)) {
        throw "CGCE-OPS-PROCESS-UNLISTED executable absent from allowlist"
    }
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
    $launch = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_process_launch"
        run_id = $runId
        sequence = 0
        created_at_utc = (Get-CgceRuntimeUtcNow)
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
        previous_receipt_sha256 = $null
    }
    $launchPath = Join-Path $ReceiptRoot "000-launch.json"
    $launchWrite = Write-CgceRuntimeJson `
        $launch $launchPath "CGCE-OPS-PROCESS-RECEIPT"
    try {
        $process = Start-Process `
            -FilePath $canonicalExecutable `
            -ArgumentList $Arguments `
            -WorkingDirectory $working `
            -PassThru
    } catch {
        throw "CGCE-OPS-PROCESS-QUERY child launch failed"
    }
    $startedAt = Get-CgceRuntimeUtcNow
    try {
        $rootRecord = Get-CimInstance -ClassName "Win32_Process" `
            -Filter ("ProcessId=" + $process.Id) -ErrorAction Stop
    } catch {
        $rootRecord = [pscustomobject]@{
            ProcessId = $process.Id
            ParentProcessId = 0
            ExecutablePath = $canonicalExecutable
            CreationTimeFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        }
    }
    $rootIdentity = Get-CgceProcessIdentityFromRecord `
        $rootRecord $canonicalExecutable
    $observed = New-Object 'Collections.Generic.List[object]'
    $bindings = New-Object 'Collections.Generic.List[object]'
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $previous = $launchWrite.checksum

    function Add-ProcessIdentity($Identity) {
        if ($script:processObserved.Count -ge 998) {
            throw "CGCE-OPS-PROCESS-RECEIPT PID receipt bound exceeded"
        }
        $isAllowed = @($script:processAllowed | Where-Object {
            Test-CgceRuntimePathEqual $_ $Identity.executable_path
        }).Count -eq 1
        if (-not $isAllowed) {
            throw "CGCE-OPS-PROCESS-UNLISTED observed descendant not allowlisted"
        }
        $key = "$($Identity.pid)|$($Identity.executable_path)|$($Identity.creation_time_filetime_utc)"
        if (-not $script:processSeen.Add($key)) { return }
        $sequence = $script:processObserved.Count + 1
        $receipt = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $script:processRunId
            sequence = $sequence
            pid = [int64]$Identity.pid
            parent_pid = [int64]$Identity.parent_pid
            executable_path = $Identity.executable_path
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
        $null = $script:processObserved.Add($receipt)
        $null = $script:processBindings.Add([pscustomobject][ordered]@{
            sequence = $sequence; path = $path; sha256 = $written.checksum
        })
        $script:processPrevious = $written.checksum
    }
    $script:processObserved = $observed
    $script:processBindings = $bindings
    $script:processSeen = $seen
    $script:processAllowed = $paths
    $script:processRunId = $runId
    $script:processReceiptRoot = $ReceiptRoot
    $script:processPrevious = $previous
    try {
        Add-ProcessIdentity $rootIdentity
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            try {
                $records = @(Get-CimInstance -ClassName "Win32_Process" -ErrorAction Stop)
            } catch {
                throw "CGCE-OPS-PROCESS-QUERY descendant query failed"
            }
            $knownPids = @($observed | ForEach-Object { [int64]$_.pid })
            $added = $true
            while ($added) {
                $added = $false
                foreach ($record in $records) {
                    if ($knownPids -contains [int64]$record.ParentProcessId) {
                        $identity = Get-CgceProcessIdentityFromRecord $record ""
                        $before = $observed.Count
                        Add-ProcessIdentity $identity
                        if ($observed.Count -gt $before) {
                            $knownPids += [int64]$identity.pid
                            $added = $true
                        }
                    }
                }
            }
            $live = 0
            foreach ($identity in @($observed)) {
                foreach ($record in $records) {
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
            if ($live -eq 0) { break }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "CGCE-OPS-PROCESS-TIMEOUT child process still active"
            }
            Start-Sleep -Milliseconds 100
        }
        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
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
            exit_at_utc = (Get-CgceRuntimeUtcNow)
            exit_code = $exitCode
            observed_processes = [object[]]$observedResult
            pid_receipts = [object[]]$bindings.ToArray()
        }
        $resultPath = Join-Path $ReceiptRoot "999-result.json"
        $resultWrite = Write-CgceRuntimeJson `
            $result $resultPath "CGCE-OPS-PROCESS-RECEIPT"
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
    }
}

Export-ModuleMember -Function @(
    "Assert-CgceNoServerActivity",
    "Assert-CgceNoForeignRunArtifacts",
    "Assert-CgceServerArguments",
    "Enable-CgceInventoryProbe",
    "Restore-CgceInventoryProbe",
    "Invoke-CgceChildProcess"
)
