Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$contractModule = Join-Path $PSScriptRoot "CgceDiscovery.Contract.psm1"
Import-Module $contractModule | Out-Null

$script:CgceInventoryEnvelopeKeys = @(
    "schema_version",
    "kind",
    "entries"
)

$script:CgceInventoryEntryKeys = @(
    "relative_path",
    "length",
    "sha256"
)

function Resolve-CgceCanonicalPath([string]$Path, [bool]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -cnotmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
        throw "CGCE-OPS-PATH absolute Windows path required"
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    } catch {
        throw "CGCE-OPS-PATH invalid path"
    }
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        ($volumeRoot -cnotmatch '^[A-Za-z]:[\\/]$' -and
            $volumeRoot -cnotmatch '^\\\\[^\\/]+[\\/][^\\/]+[\\/]$')) {
        throw "CGCE-OPS-PATH absolute drive or UNC path required"
    }

    $trimmedRoot = $volumeRoot.TrimEnd('\', '/')
    $canonicalRoot = $trimmedRoot + "\"
    $trimmedFull = $full.TrimEnd('\', '/')
    if ($trimmedFull.Equals($trimmedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $full = $canonicalRoot
    } else {
        $full = $trimmedFull
    }

    if ($MustExist) {
        try {
            $exists = Test-Path -LiteralPath $full
        } catch {
            throw "CGCE-OPS-PATH cannot inspect path"
        }
        if (-not $exists) {
            throw "CGCE-OPS-PATH missing path"
        }
    }
    return $full
}

function Test-CgceCanonicalPathAtOrBelow([string]$Path, [string]$Root) {
    if ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = if ($Root.EndsWith("\")) { $Root } else { $Root + "\" }
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CgceEqualCanonicalPath([string]$Expected, [string]$Actual) {
    $canonicalExpected = Resolve-CgceCanonicalPath -Path $Expected -MustExist $false
    $canonicalActual = Resolve-CgceCanonicalPath -Path $Actual -MustExist $false
    if (-not $canonicalExpected.Equals(
            $canonicalActual,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-PATH canonical paths differ"
    }
}

function Assert-CgcePathContainedBy([string]$Path, [string]$Root) {
    $canonicalPath = Resolve-CgceCanonicalPath -Path $Path -MustExist $false
    $canonicalRoot = Resolve-CgceCanonicalPath -Path $Root -MustExist $false
    if (-not (Test-CgceCanonicalPathAtOrBelow -Path $canonicalPath -Root $canonicalRoot)) {
        throw "CGCE-OPS-PATH path escapes root"
    }
}

function Assert-CgceDistinctRoots([string[]]$Paths) {
    if ($null -eq $Paths -or $Paths.Count -lt 2) {
        throw "CGCE-OPS-PATH-OVERLAP at least two roots are required"
    }
    $canonical = @(
        foreach ($path in $Paths) {
            Resolve-CgceCanonicalPath -Path $path -MustExist $false
        }
    )
    for ($left = 0; $left -lt $canonical.Count; $left += 1) {
        for ($right = $left + 1; $right -lt $canonical.Count; $right += 1) {
            if ((Test-CgceCanonicalPathAtOrBelow `
                    -Path $canonical[$left] -Root $canonical[$right]) -or
                (Test-CgceCanonicalPathAtOrBelow `
                    -Path $canonical[$right] -Root $canonical[$left])) {
                throw "CGCE-OPS-PATH-OVERLAP roots overlap"
            }
        }
    }
}

function Test-CgceItemIsReparsePoint($Item) {
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-CgceNoReparseInPath([string]$Path) {
    $canonical = Resolve-CgceCanonicalPath -Path $Path -MustExist $false
    $volumeRoot = [System.IO.Path]::GetPathRoot($canonical)
    $current = $volumeRoot

    try {
        $rootExists = Test-Path -LiteralPath $current
    } catch {
        throw "CGCE-OPS-PATH cannot inspect volume root"
    }
    if ($rootExists) {
        try {
            $rootItem = Get-Item -LiteralPath $current -Force
        } catch {
            throw "CGCE-OPS-PATH cannot inspect volume root"
        }
        if (Test-CgceItemIsReparsePoint $rootItem) {
            throw "CGCE-OPS-REPARSE reparse point found in path"
        }
    }

    $relative = $canonical.Substring($volumeRoot.Length)
    if ($relative.Length -eq 0) {
        return
    }
    foreach ($component in $relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [System.IO.Path]::Combine($current, $component)
        try {
            $exists = Test-Path -LiteralPath $current
        } catch {
            throw "CGCE-OPS-PATH cannot inspect path component"
        }
        if (-not $exists) {
            break
        }
        try {
            $item = Get-Item -LiteralPath $current -Force
        } catch {
            throw "CGCE-OPS-PATH cannot inspect path component"
        }
        if (Test-CgceItemIsReparsePoint $item) {
            throw "CGCE-OPS-REPARSE reparse point found in path"
        }
    }
}

function Get-CgceTreeFilesNoReparse([string]$Root) {
    $canonical = Resolve-CgceCanonicalPath -Path $Root -MustExist $true
    Assert-CgceNoReparseInPath -Path $canonical
    try {
        $rootItem = Get-Item -LiteralPath $canonical -Force
    } catch {
        throw "CGCE-OPS-PATH cannot inspect tree root"
    }
    if (-not $rootItem.PSIsContainer) {
        throw "CGCE-OPS-PATH tree root must be a directory"
    }
    if (Test-CgceItemIsReparsePoint $rootItem) {
        throw "CGCE-OPS-REPARSE tree root is a reparse point"
    }

    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push([System.IO.DirectoryInfo]$rootItem)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $currentDirectory = Get-Item -LiteralPath $directory.FullName -Force
        } catch {
            throw "CGCE-OPS-PATH cannot enumerate tree"
        }
        if (-not $currentDirectory.PSIsContainer) {
            throw "CGCE-OPS-PATH tree directory changed type"
        }
        if (Test-CgceItemIsReparsePoint $currentDirectory) {
            throw "CGCE-OPS-REPARSE reparse point found before traversal"
        }
        try {
            $children = @(Get-ChildItem -LiteralPath $currentDirectory.FullName -Force)
        } catch {
            throw "CGCE-OPS-PATH cannot enumerate tree"
        }
        foreach ($child in $children) {
            if (Test-CgceItemIsReparsePoint $child) {
                throw "CGCE-OPS-REPARSE reparse point found in tree"
            }
            if ($child.PSIsContainer) {
                $pending.Push([System.IO.DirectoryInfo]$child)
            } else {
                Write-Output $child
            }
        }
    }
}

function Assert-CgceTreeHasNoReparsePoints([string]$Root) {
    $null = @(Get-CgceTreeFilesNoReparse -Root $Root)
}

function Sort-CgceInventoryRecords([object[]]$Records) {
    $sorted = [object[]]@($Records)
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
    return $sorted
}

function Get-CgceTreeInventory([string]$Root) {
    $canonical = Resolve-CgceCanonicalPath -Path $Root -MustExist $true
    $prefix = if ($canonical.EndsWith("\")) { $canonical } else { $canonical + "\" }
    $records = @(
        foreach ($file in @(Get-CgceTreeFilesNoReparse -Root $canonical)) {
            if (-not $file.FullName.StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "CGCE-OPS-INVENTORY file escaped inventory root"
            }
            [pscustomobject][ordered]@{
                relative_path = $file.FullName.Substring($prefix.Length).Replace('\', '/')
                length = [int64]$file.Length
                sha256 = (Get-CgceSha256 -Path $file.FullName)
            }
        }
    )
    $sorted = @(Sort-CgceInventoryRecords -Records $records)
    return ConvertTo-CgceValidatedInventory -Entries $sorted
}

function Assert-CgceExactInventoryKeys($Value, [string[]]$Expected) {
    if ($null -eq $Value -or $Value -is [string]) {
        throw "CGCE-OPS-INVENTORY object is required"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Expected.Count) {
        throw "CGCE-OPS-INVENTORY exact key set required"
    }
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
    foreach ($key in $Expected) {
        $null = $expectedSet.Add($key)
    }
    foreach ($key in $actual) {
        if (-not $expectedSet.Contains($key)) {
            throw "CGCE-OPS-INVENTORY unknown or missing field"
        }
    }
}

function Assert-CgceInventoryRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith("/") -or
        $Path.Contains("\") -or
        $Path.Contains(":") -or
        $Path -cmatch '[\x00-\x1f]') {
        throw "CGCE-OPS-INVENTORY invalid relative path"
    }
    foreach ($component in $Path.Split('/')) {
        if ($component.Length -eq 0 -or $component -ceq "." -or $component -ceq "..") {
            throw "CGCE-OPS-INVENTORY invalid relative path"
        }
    }
}

function ConvertTo-CgceInventoryLength($Value) {
    if ($null -eq $Value) {
        throw "CGCE-OPS-INVENTORY invalid file length"
    }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    $allowedTypeCodes = @(
        [TypeCode]::Byte,
        [TypeCode]::SByte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Decimal
    )
    if ($allowedTypeCodes -notcontains $typeCode) {
        throw "CGCE-OPS-INVENTORY invalid file length"
    }
    try {
        $decimalLength = [decimal]$Value
    } catch {
        throw "CGCE-OPS-INVENTORY invalid file length"
    }
    if ($decimalLength -lt 0 -or
        $decimalLength -gt [int64]::MaxValue -or
        [decimal]::Truncate($decimalLength) -ne $decimalLength) {
        throw "CGCE-OPS-INVENTORY invalid file length"
    }
    return [int64]$decimalLength
}

function ConvertTo-CgceValidatedInventory([object[]]$Entries) {
    if ($null -eq $Entries -or $Entries -isnot [System.Array]) {
        throw "CGCE-OPS-INVENTORY dense entries array required"
    }
    $validated = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $previousPath = $null
    foreach ($entry in $Entries) {
        Assert-CgceExactInventoryKeys -Value $entry -Expected $script:CgceInventoryEntryKeys
        if ($entry.relative_path -isnot [string]) {
            throw "CGCE-OPS-INVENTORY invalid relative path"
        }
        Assert-CgceInventoryRelativePath -Path $entry.relative_path
        if ($null -ne $previousPath -and
            [StringComparer]::Ordinal.Compare(
                [string]$previousPath,
                [string]$entry.relative_path
            ) -ge 0) {
            throw "CGCE-OPS-INVENTORY entries must be strictly sorted"
        }
        if (-not $seen.Add($entry.relative_path)) {
            throw "CGCE-OPS-INVENTORY duplicate relative path"
        }
        $length = ConvertTo-CgceInventoryLength $entry.length
        if ($entry.sha256 -isnot [string] -or
            $entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "CGCE-OPS-INVENTORY invalid SHA-256"
        }
        $null = $validated.Add([pscustomobject][ordered]@{
            relative_path = $entry.relative_path
            length = $length
            sha256 = $entry.sha256
        })
        $previousPath = $entry.relative_path
    }
    return [object[]]$validated.ToArray()
}

function Compare-CgceInventory([object[]]$Expected, [object[]]$Actual) {
    $validatedExpected = @(ConvertTo-CgceValidatedInventory -Entries $Expected)
    $validatedActual = @(ConvertTo-CgceValidatedInventory -Entries $Actual)
    if ($validatedExpected.Count -ne $validatedActual.Count) {
        throw "CGCE-OPS-INVENTORY entry count differs"
    }
    for ($index = 0; $index -lt $validatedExpected.Count; $index += 1) {
        if ($validatedExpected[$index].relative_path -cne
                $validatedActual[$index].relative_path -or
            $validatedExpected[$index].length -ne
                $validatedActual[$index].length -or
            $validatedExpected[$index].sha256 -cne
                $validatedActual[$index].sha256) {
            throw "CGCE-OPS-INVENTORY entry differs"
        }
    }
}

function Write-CgceInventory(
    [object[]]$Entries,
    [string]$Path,
    [string]$Kind
) {
    if ([string]::IsNullOrWhiteSpace($Kind)) {
        throw "CGCE-OPS-INVENTORY kind is required"
    }
    $validated = @(ConvertTo-CgceValidatedInventory -Entries $Entries)
    $envelope = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = $Kind
        entries = [object[]]$validated
    }
    Write-CgceJsonAtomic -Value $envelope -Path $Path
    return Get-CgceSha256 -Path $Path
}

function Read-CgceInventory([string]$Path, [string]$ExpectedKind) {
    if ([string]::IsNullOrWhiteSpace($ExpectedKind)) {
        throw "CGCE-OPS-INVENTORY expected kind is required"
    }
    try {
        $envelope = Read-CgceJsonObject -Path $Path
    } catch {
        throw "CGCE-OPS-INVENTORY invalid inventory document"
    }
    Assert-CgceExactInventoryKeys `
        -Value $envelope `
        -Expected $script:CgceInventoryEnvelopeKeys
    if ($envelope.schema_version -isnot [string] -or
        $envelope.schema_version -cne "1.0" -or
        $envelope.kind -isnot [string] -or
        $envelope.kind -cne $ExpectedKind -or
        $envelope.entries -isnot [System.Array]) {
        throw "CGCE-OPS-INVENTORY invalid inventory envelope"
    }
    return ConvertTo-CgceValidatedInventory -Entries ([object[]]$envelope.entries)
}

function Join-CgceWindowsPath([string]$Parent, [string]$Child) {
    return [System.IO.Path]::Combine($Parent, $Child)
}

function New-CgceRunPaths(
    [string]$ServerRoot,
    [string]$SavedPath,
    [string]$Ue4ssRoot,
    [string]$RunRoot,
    [string]$RunId
) {
    if (-not (Test-CgceRunId $RunId)) {
        throw "CGCE-OPS-PATH invalid run identifier"
    }
    $canonicalServerRoot = Resolve-CgceCanonicalPath -Path $ServerRoot -MustExist $false
    $canonicalSavedPath = Resolve-CgceCanonicalPath -Path $SavedPath -MustExist $false
    $canonicalUe4ssRoot = Resolve-CgceCanonicalPath -Path $Ue4ssRoot -MustExist $false
    $canonicalRunRoot = Resolve-CgceCanonicalPath -Path $RunRoot -MustExist $false
    $expectedSavedPath = Join-CgceWindowsPath `
        -Parent $canonicalServerRoot `
        -Child "Pal\Saved"
    if (-not $canonicalSavedPath.Equals(
            $expectedSavedPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-PATH Saved path must be the active server Saved path"
    }

    $runDirectory = Join-CgceWindowsPath -Parent $canonicalRunRoot -Child $RunId
    $modsRoot = Join-CgceWindowsPath -Parent $canonicalUe4ssRoot -Child "Mods"
    $modsTxt = Join-CgceWindowsPath -Parent $modsRoot -Child "mods.txt"
    $probeStaged = Join-CgceWindowsPath `
        -Parent $modsRoot `
        -Child "CGCEDiscoveryInventory"
    $objectDump = Join-CgceWindowsPath `
        -Parent $canonicalUe4ssRoot `
        -Child "UE4SS_ObjectDump.txt"
    $cxxHeaderDump = Join-CgceWindowsPath `
        -Parent $canonicalUe4ssRoot `
        -Child "CXXHeaderDump"
    $ue4ssLog = Join-CgceWindowsPath `
        -Parent $canonicalUe4ssRoot `
        -Child "UE4SS.log"
    $probeReceipts = Join-CgceWindowsPath `
        -Parent $runDirectory `
        -Child "receipts\probe"
    $processReceipts = Join-CgceWindowsPath `
        -Parent $runDirectory `
        -Child "receipts\process"

    return [pscustomobject][ordered]@{
        server_root = $canonicalServerRoot
        run_root = $canonicalRunRoot
        run_directory = $runDirectory
        state = (Join-CgceWindowsPath -Parent $runDirectory -Child "run-state.json")
        genesis_state = (Join-CgceWindowsPath -Parent $runDirectory -Child "run-state.genesis.json")
        control_evidence = (Join-CgceWindowsPath -Parent $runDirectory -Child "control-evidence.json")
        active_run_marker = (Join-CgceWindowsPath -Parent $canonicalServerRoot -Child ".cgce-discovery-active.json")
        completed_run_marker = (Join-CgceWindowsPath -Parent $canonicalServerRoot -Child ".cgce-discovery-completed-$RunId.json")
        active_saved = $canonicalSavedPath
        inactive_original = "$canonicalSavedPath.cgce-original-$RunId"
        quarantined_clone = "$canonicalSavedPath.cgce-test-$RunId"
        backup_saved = (Join-CgceWindowsPath -Parent $runDirectory -Child "backup\Saved")
        original_inventory = (Join-CgceWindowsPath -Parent $runDirectory -Child "inventories\original.json")
        backup_inventory = (Join-CgceWindowsPath -Parent $runDirectory -Child "inventories\backup.json")
        clone_inventory = (Join-CgceWindowsPath -Parent $runDirectory -Child "inventories\clone.json")
        restored_inventory = (Join-CgceWindowsPath -Parent $runDirectory -Child "inventories\restored.json")
        ue4ss_root = $canonicalUe4ssRoot
        ue4ss_dll = (Join-CgceWindowsPath -Parent $canonicalUe4ssRoot -Child "UE4SS.dll")
        mods_txt = $modsTxt
        mods_original = "$modsTxt.cgce-original-$RunId"
        mods_test = "$modsTxt.cgce-test-$RunId"
        probe_staged = $probeStaged
        probe_quarantine = "$probeStaged.cgce-test-$RunId"
        object_dump = $objectDump
        object_dump_original = "$objectDump.cgce-original-$RunId"
        object_dump_quarantine = "$objectDump.cgce-test-$RunId"
        cxx_header_dump = $cxxHeaderDump
        cxx_header_dump_original = "$cxxHeaderDump.cgce-original-$RunId"
        cxx_header_dump_quarantine = "$cxxHeaderDump.cgce-test-$RunId"
        ue4ss_log = $ue4ssLog
        ue4ss_log_original = "$ue4ssLog.cgce-original-$RunId"
        ue4ss_log_quarantine = "$ue4ssLog.cgce-test-$RunId"
        capture = (Join-CgceWindowsPath -Parent $runDirectory -Child "capture")
        probe_intent = (Join-CgceWindowsPath -Parent $probeReceipts -Child "000-probe-intent.json")
        probe_receipt = (Join-CgceWindowsPath -Parent $probeReceipts -Child "999-probe-final.json")
        probe_receipts = $probeReceipts
        process_launch_receipt = (Join-CgceWindowsPath -Parent $processReceipts -Child "000-launch.json")
        process_result_receipt = (Join-CgceWindowsPath -Parent $processReceipts -Child "999-result.json")
        process_receipts = $processReceipts
        capture_inventory = (Join-CgceWindowsPath -Parent $runDirectory -Child "capture-inventory.json")
        restore_receipts = (Join-CgceWindowsPath -Parent $runDirectory -Child "receipts\restore")
    }
}

function Copy-CgceFileVerified([string]$Source, [string]$Destination) {
    $canonicalSource = Resolve-CgceCanonicalPath -Path $Source -MustExist $false
    try {
        $sourceIsFile = Test-Path -LiteralPath $canonicalSource -PathType Leaf
    } catch {
        throw "CGCE-OPS-COPY cannot inspect source file"
    }
    if (-not $sourceIsFile) {
        throw "CGCE-OPS-COPY missing source file"
    }
    $canonicalDestination = Resolve-CgceCanonicalPath `
        -Path $Destination `
        -MustExist $false
    try {
        $destinationExists = Test-Path -LiteralPath $canonicalDestination
    } catch {
        throw "CGCE-OPS-COPY cannot inspect destination file"
    }
    if ($destinationExists) {
        throw "CGCE-OPS-DESTINATION-EXISTS destination exists"
    }
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceNoReparseInPath -Path $canonicalDestination

    try {
        Copy-Item `
            -LiteralPath $canonicalSource `
            -Destination $canonicalDestination `
            -ErrorAction Stop
    } catch {
        throw "CGCE-OPS-COPY file copy failed"
    }
    try {
        $sourceItem = Get-Item -LiteralPath $canonicalSource -Force
        $destinationItem = Get-Item -LiteralPath $canonicalDestination -Force
        $sourceChecksum = Get-CgceSha256 -Path $canonicalSource
        $destinationChecksum = Get-CgceSha256 -Path $canonicalDestination
    } catch {
        throw "CGCE-OPS-COPY copied file cannot be verified"
    }
    if ([int64]$sourceItem.Length -ne [int64]$destinationItem.Length -or
        $sourceChecksum -cne $destinationChecksum) {
        throw "CGCE-OPS-COPY copied file differs"
    }
    return [pscustomobject][ordered]@{
        length = [int64]$destinationItem.Length
        sha256 = $destinationChecksum
    }
}

function Copy-CgceTreeVerified([string]$Source, [string]$Destination) {
    $canonicalSource = Resolve-CgceCanonicalPath -Path $Source -MustExist $false
    try {
        $sourceIsDirectory = Test-Path -LiteralPath $canonicalSource -PathType Container
    } catch {
        throw "CGCE-OPS-COPY cannot inspect source tree"
    }
    if (-not $sourceIsDirectory) {
        throw "CGCE-OPS-COPY missing source tree"
    }
    $canonicalDestination = Resolve-CgceCanonicalPath `
        -Path $Destination `
        -MustExist $false
    try {
        $destinationExists = Test-Path -LiteralPath $canonicalDestination
    } catch {
        throw "CGCE-OPS-COPY cannot inspect destination tree"
    }
    if ($destinationExists) {
        throw "CGCE-OPS-DESTINATION-EXISTS destination exists"
    }
    Assert-CgceDistinctRoots -Paths @($canonicalSource, $canonicalDestination)
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalSource
    $sourceInventory = @(Get-CgceTreeInventory -Root $canonicalSource)

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        throw "CGCE-OPS-COPY SystemRoot is unavailable"
    }
    $robocopy = [System.IO.Path]::Combine(
        $env:SystemRoot,
        "System32",
        "robocopy.exe"
    )
    if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
        throw "CGCE-OPS-COPY robocopy is unavailable"
    }
    try {
        & $robocopy `
            $canonicalSource `
            $canonicalDestination `
            "/E" `
            "/COPY:DAT" `
            "/DCOPY:DAT" `
            "/R:1" `
            "/W:1" `
            "/XJ" | Out-Null
        $robocopyExitCode = [int]$LASTEXITCODE
    } catch {
        throw "CGCE-OPS-COPY robocopy invocation failed"
    }
    if ($robocopyExitCode -lt 0 -or $robocopyExitCode -gt 7) {
        throw "CGCE-OPS-COPY robocopy failed"
    }

    Assert-CgceNoReparseInPath -Path $canonicalDestination
    $destinationInventory = @(Get-CgceTreeInventory -Root $canonicalDestination)
    Compare-CgceInventory `
        -Expected $sourceInventory `
        -Actual $destinationInventory
    return $destinationInventory
}

function Move-CgceDirectoryNoOverwrite([string]$Source, [string]$Destination) {
    $canonicalSource = Resolve-CgceCanonicalPath -Path $Source -MustExist $false
    try {
        $sourceIsDirectory = Test-Path -LiteralPath $canonicalSource -PathType Container
    } catch {
        throw "CGCE-OPS-PATH cannot inspect source directory"
    }
    if (-not $sourceIsDirectory) {
        throw "CGCE-OPS-PATH missing source directory"
    }
    $canonicalDestination = Resolve-CgceCanonicalPath `
        -Path $Destination `
        -MustExist $false
    try {
        $destinationExists = Test-Path -LiteralPath $canonicalDestination
    } catch {
        throw "CGCE-OPS-PATH cannot inspect destination directory"
    }
    if ($destinationExists) {
        throw "CGCE-OPS-DESTINATION-EXISTS destination exists"
    }
    Assert-CgceDistinctRoots -Paths @($canonicalSource, $canonicalDestination)
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalSource

    $sourceVolume = [System.IO.Path]::GetPathRoot($canonicalSource)
    $destinationVolume = [System.IO.Path]::GetPathRoot($canonicalDestination)
    if (-not $sourceVolume.Equals(
            $destinationVolume,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-PATH move requires equal volume roots"
    }
    try {
        Move-Item `
            -LiteralPath $canonicalSource `
            -Destination $canonicalDestination `
            -ErrorAction Stop
    } catch {
        throw "CGCE-OPS-COPY directory rename failed"
    }
}

Export-ModuleMember -Function @(
    "Resolve-CgceCanonicalPath",
    "Assert-CgceEqualCanonicalPath",
    "Assert-CgcePathContainedBy",
    "Assert-CgceDistinctRoots",
    "Assert-CgceNoReparseInPath",
    "Assert-CgceTreeHasNoReparsePoints",
    "New-CgceRunPaths",
    "Get-CgceTreeInventory",
    "Compare-CgceInventory",
    "Write-CgceInventory",
    "Read-CgceInventory",
    "Copy-CgceFileVerified",
    "Copy-CgceTreeVerified",
    "Move-CgceDirectoryNoOverwrite"
)
