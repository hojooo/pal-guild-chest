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

$script:CgceTestPublishSeam = $null
$script:CgceTestRobocopySeam = $null
$script:CgceTestLayoutSeam = $null
$script:CgceTestFreeSpaceSeam = $null

function Resolve-CgceCanonicalPath([string]$Path, [bool]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -cnotmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|\z))') {
        throw "CGCE-OPS-PATH absolute Windows path required"
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    } catch {
        throw "CGCE-OPS-PATH invalid path"
    }
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        ($volumeRoot -cnotmatch '^[A-Za-z]:[\\/]\z' -and
            $volumeRoot -cnotmatch '^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/])?\z')) {
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
            $entry.sha256 -cnotmatch '^[0-9a-f]{64}\z') {
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

function Assert-CgceExactRunPaths($Paths) {
    $expected = New-CgceRunPaths `
        -ServerRoot $Paths.server_root `
        -SavedPath $Paths.active_saved `
        -Ue4ssRoot $Paths.ue4ss_root `
        -RunRoot $Paths.run_root `
        -RunId ([System.IO.Path]::GetFileName($Paths.run_directory))
    $expectedProperties = @($expected.PSObject.Properties)
    $actualProperties = @($Paths.PSObject.Properties)
    if ($actualProperties.Count -ne 41 -or
        $actualProperties.Count -ne $expectedProperties.Count) {
        throw "CGCE-OPS-PATH run Paths key drift"
    }
    for ($index = 0; $index -lt $expectedProperties.Count; $index += 1) {
        if ($actualProperties[$index].Name -cne $expectedProperties[$index].Name) {
            throw "CGCE-OPS-PATH run Paths key drift"
        }
        $actual = Resolve-CgceCanonicalPath `
            -Path ([string]$actualProperties[$index].Value) `
            -MustExist $false
        $expectedValue = Resolve-CgceCanonicalPath `
            -Path ([string]$expectedProperties[$index].Value) `
            -MustExist $false
        if (-not $actual.Equals(
                $expectedValue,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "CGCE-OPS-PATH run Paths value drift"
        }
    }
}

function Assert-CgceExactPublishedRunLayout([string]$Root) {
    Assert-CgceNoReparseInPath -Path $Root
    Assert-CgceTreeHasNoReparsePoints -Root $Root
    $expected = @(
        "backup",
        "before",
        "capture",
        "inventories",
        "receipts",
        "receipts\probe",
        "receipts\process",
        "receipts\restore"
    )
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    $actual = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
        if (-not $item.PSIsContainer) {
            throw "CGCE-OPS-BLOCKED run layout contains an unexpected file"
        }
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\', '/')
        $null = $actual.Add($relative)
    }
    $actualValues = $actual.ToArray()
    [Array]::Sort($actualValues, [StringComparer]::Ordinal)
    if ([string]::Join("`n", $expected) -cne
        [string]::Join("`n", $actualValues)) {
        throw "CGCE-OPS-BLOCKED run layout directory shape drift"
    }
}

function Initialize-CgceRunLayout($Paths) {
    Assert-CgceExactRunPaths $Paths
    $runRoot = Resolve-CgceCanonicalPath -Path $Paths.run_root -MustExist $true
    $runDirectory = Resolve-CgceCanonicalPath `
        -Path $Paths.run_directory `
        -MustExist $false
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
        throw "CGCE-OPS-STATE-EXISTS run root is not a directory"
    }
    Assert-CgceNoReparseInPath -Path $runRoot
    $runId = [System.IO.Path]::GetFileName($runDirectory)
    $fixedStaging = Join-Path $runRoot ".$runId.cgce-stage-layout"
    if ((Test-Path -LiteralPath $runDirectory) -or
        (Test-Path -LiteralPath $fixedStaging)) {
        throw "CGCE-OPS-STATE-EXISTS run layout already exists"
    }
    $uniqueStaging = Join-Path `
        $runRoot `
        (".$runId.cgce-stage-layout-" + [guid]::NewGuid().ToString("N"))
    if (Test-Path -LiteralPath $uniqueStaging) {
        throw "CGCE-OPS-STATE-EXISTS unique layout staging exists"
    }
    try {
        $null = [System.IO.Directory]::CreateDirectory($uniqueStaging)
        foreach ($relative in @(
            "backup",
            "inventories",
            "capture",
            "before",
            "receipts\probe",
            "receipts\process",
            "receipts\restore"
        )) {
            $null = [System.IO.Directory]::CreateDirectory(
                (Join-Path $uniqueStaging $relative)
            )
        }
        Assert-CgceExactPublishedRunLayout -Root $uniqueStaging
        $context = [pscustomobject]@{
            unique_staging = $uniqueStaging
            fixed_staging = $fixedStaging
            destination = $runDirectory
        }
        if ($null -ne $script:CgceTestLayoutSeam) {
            $null = & $script:CgceTestLayoutSeam "before-claim" $context
        }
        try {
            [System.IO.Directory]::Move($uniqueStaging, $fixedStaging)
        } catch {
            if (Test-Path -LiteralPath $fixedStaging) {
                throw "CGCE-OPS-STATE-EXISTS fixed layout staging was claimed"
            }
            throw "CGCE-OPS-BLOCKED fixed layout staging claim failed"
        }
        if ($null -ne $script:CgceTestLayoutSeam) {
            $null = & $script:CgceTestLayoutSeam "after-claim" $context
        }
        Assert-CgceExactPublishedRunLayout -Root $fixedStaging
        if ($null -ne $script:CgceTestLayoutSeam) {
            $null = & $script:CgceTestLayoutSeam "before-publish" $context
        }
        Assert-CgceExactPublishedRunLayout -Root $fixedStaging
        if (Test-Path -LiteralPath $runDirectory) {
            throw "CGCE-OPS-STATE-EXISTS final run directory appeared"
        }
        [System.IO.Directory]::Move($fixedStaging, $runDirectory)
    } catch {
        if ($_.Exception.Message -like "CGCE-OPS-STATE-EXISTS*") {
            throw
        }
        if ($_.Exception.Message -like "CGCE-OPS-BLOCKED*") {
            throw
        }
        throw "CGCE-OPS-BLOCKED run layout publication failed"
    }
    Assert-CgceExactPublishedRunLayout -Root $runDirectory
}

function Add-CgceCheckedInt64([int64]$Left, [int64]$Right) {
    if ($Left -lt 0 -or $Right -lt 0 -or
        $Left -gt ([int64]::MaxValue - $Right)) {
        throw "CGCE-OPS-DISK byte count overflow"
    }
    return [int64]($Left + $Right)
}

function Get-CgceAvailableFreeSpace([string]$VolumeRoot) {
    if ($null -ne $script:CgceTestFreeSpaceSeam) {
        $value = & $script:CgceTestFreeSpaceSeam $VolumeRoot
    } else {
        if ($VolumeRoot -cnotmatch '^[A-Za-z]:\\\z') {
            throw "CGCE-OPS-DISK unsupported volume"
        }
        try {
            $drive = [System.IO.DriveInfo]::new($VolumeRoot)
            if (-not $drive.IsReady) {
                throw "volume is not ready"
            }
            $value = $drive.AvailableFreeSpace
        } catch {
            throw "CGCE-OPS-DISK free space query failed"
        }
    }
    if ($null -eq $value -or $value -is [bool] -or
        $value -isnot [ValueType]) {
        throw "CGCE-OPS-DISK invalid free space result"
    }
    try {
        $decimalValue = [decimal]$value
    } catch {
        throw "CGCE-OPS-DISK invalid free space result"
    }
    if ([decimal]::Truncate($decimalValue) -ne $decimalValue -or
        $decimalValue -lt 0 -or
        $decimalValue -gt [decimal][int64]::MaxValue) {
        throw "CGCE-OPS-DISK invalid free space result"
    }
    return [int64]$decimalValue
}

function Assert-CgceDiscoveryDiskCapacity(
    [object[]]$Entries,
    [string]$BackupPath,
    [string]$ClonePath
) {
    if ($null -eq $Entries) {
        throw "CGCE-OPS-DISK inventory is required"
    }
    $size = [int64]0
    foreach ($entry in $Entries) {
        if ($null -eq $entry -or
            $null -eq $entry.PSObject.Properties["length"] -or
            $entry.length -is [bool] -or
            $entry.length -isnot [ValueType]) {
            throw "CGCE-OPS-DISK invalid inventory length"
        }
        try {
            $lengthValue = [decimal]$entry.length
        } catch {
            throw "CGCE-OPS-DISK invalid inventory length"
        }
        if ([decimal]::Truncate($lengthValue) -ne $lengthValue -or
            $lengthValue -lt 0 -or
            $lengthValue -gt [decimal][int64]::MaxValue) {
            throw "CGCE-OPS-DISK invalid inventory length"
        }
        $size = Add-CgceCheckedInt64 $size ([int64]$lengthValue)
    }

    $required = [System.Collections.Generic.Dictionary[string,int64]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($destination in @($BackupPath, $ClonePath)) {
        $canonical = Resolve-CgceCanonicalPath `
            -Path $destination `
            -MustExist $false
        $volumeRoot = [System.IO.Path]::GetPathRoot($canonical)
        if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
            throw "CGCE-OPS-DISK unsupported volume"
        }
        if ($required.ContainsKey($volumeRoot)) {
            $required[$volumeRoot] = Add-CgceCheckedInt64 `
                $required[$volumeRoot] `
                $size
        } else {
            $null = $required.Add($volumeRoot, $size)
        }
    }
    foreach ($entry in $required.GetEnumerator()) {
        $available = Get-CgceAvailableFreeSpace $entry.Key
        if ($available -lt $entry.Value) {
            throw "CGCE-OPS-DISK insufficient free space"
        }
    }
}

function New-CgceStagingPath([string]$Destination, [string]$Kind) {
    $parent = [System.IO.Path]::GetDirectoryName($Destination)
    $leaf = [System.IO.Path]::GetFileName($Destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or
        [string]::IsNullOrWhiteSpace($leaf)) {
        throw "CGCE-OPS-PATH destination must have a parent and leaf"
    }
    for ($attempt = 0; $attempt -lt 16; $attempt += 1) {
        $candidate = [System.IO.Path]::Combine(
            $parent,
            ".$leaf.cgce-stage-$Kind-" + [guid]::NewGuid().ToString("N")
        )
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw "CGCE-OPS-COPY unique staging path unavailable"
}

function Invoke-CgceTestPublishSeam([string]$Phase, $Context) {
    if ($null -ne $script:CgceTestPublishSeam) {
        $null = & $script:CgceTestPublishSeam $Phase $Context
    }
}

function Invoke-CgceRobocopy(
    [string]$Source,
    [string]$Staging,
    [string[]]$Arguments
) {
    if ($null -ne $script:CgceTestRobocopySeam) {
        $result = & $script:CgceTestRobocopySeam $Source $Staging $Arguments
        return [int]$result
    }
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
        & $robocopy $Source $Staging $Arguments | Out-Null
        return [int]$LASTEXITCODE
    } catch {
        throw "CGCE-OPS-COPY robocopy invocation failed"
    }
}

function Get-CgceVerifiedFileRecord([string]$Expected, [string]$Actual) {
    try {
        $expectedItem = Get-Item -LiteralPath $Expected -Force
        $actualItem = Get-Item -LiteralPath $Actual -Force
        $expectedChecksum = Get-CgceSha256 -Path $Expected
        $actualChecksum = Get-CgceSha256 -Path $Actual
    } catch {
        throw "CGCE-OPS-COPY copied file cannot be verified"
    }
    if ([int64]$expectedItem.Length -ne [int64]$actualItem.Length -or
        $expectedChecksum -cne $actualChecksum) {
        throw "CGCE-OPS-COPY copied file differs"
    }
    return [pscustomobject][ordered]@{
        length = [int64]$actualItem.Length
        sha256 = $actualChecksum
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

    $staging = New-CgceStagingPath `
        -Destination $canonicalDestination `
        -Kind "file"
    Assert-CgceNoReparseInPath -Path $staging
    try {
        [System.IO.File]::Copy($canonicalSource, $staging, $false)
    } catch {
        throw "CGCE-OPS-COPY file staging failed"
    }
    $null = Get-CgceVerifiedFileRecord `
        -Expected $canonicalSource `
        -Actual $staging
    $context = [pscustomobject]@{
        source = $canonicalSource
        staging = $staging
        destination = $canonicalDestination
    }
    Invoke-CgceTestPublishSeam -Phase "file-before-revalidate" -Context $context
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceNoReparseInPath -Path $staging
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    Invoke-CgceTestPublishSeam -Phase "file-before-publish" -Context $context
    try {
        [System.IO.File]::Move($staging, $canonicalDestination)
    } catch {
        if (Test-Path -LiteralPath $canonicalDestination) {
            throw "CGCE-OPS-DESTINATION-EXISTS destination appeared before publication"
        }
        throw "CGCE-OPS-COPY file publication failed"
    }
    return Get-CgceVerifiedFileRecord `
        -Expected $canonicalSource `
        -Actual $canonicalDestination
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

    $staging = New-CgceStagingPath `
        -Destination $canonicalDestination `
        -Kind "tree"
    Assert-CgceDistinctRoots -Paths @(
        $canonicalSource,
        $canonicalDestination,
        $staging
    )
    Assert-CgceNoReparseInPath -Path $staging
    $robocopyArguments = @(
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/R:1",
        "/W:1",
        "/XJ"
    )
    $robocopyExitCode = Invoke-CgceRobocopy `
        -Source $canonicalSource `
        -Staging $staging `
        -Arguments $robocopyArguments
    if ($robocopyExitCode -lt 0 -or $robocopyExitCode -gt 7) {
        throw "CGCE-OPS-COPY robocopy failed"
    }

    $stagingInventory = @(Get-CgceTreeInventory -Root $staging)
    Compare-CgceInventory `
        -Expected $sourceInventory `
        -Actual $stagingInventory
    $context = [pscustomobject]@{
        source = $canonicalSource
        staging = $staging
        destination = $canonicalDestination
    }
    Invoke-CgceTestPublishSeam -Phase "tree-before-revalidate" -Context $context
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalSource
    Assert-CgceNoReparseInPath -Path $staging
    Assert-CgceTreeHasNoReparsePoints -Root $staging
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    $sourceBeforePublication = @(Get-CgceTreeInventory -Root $canonicalSource)
    Compare-CgceInventory `
        -Expected $sourceInventory `
        -Actual $sourceBeforePublication
    Compare-CgceInventory `
        -Expected $sourceBeforePublication `
        -Actual $stagingInventory
    Invoke-CgceTestPublishSeam -Phase "tree-before-publish" -Context $context
    try {
        [System.IO.Directory]::Move($staging, $canonicalDestination)
    } catch {
        if (Test-Path -LiteralPath $canonicalDestination) {
            throw "CGCE-OPS-DESTINATION-EXISTS destination appeared before publication"
        }
        throw "CGCE-OPS-COPY tree publication failed"
    }
    Invoke-CgceTestPublishSeam -Phase "tree-after-publish" -Context $context
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalSource
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalDestination
    $sourceAfterPublication = @(Get-CgceTreeInventory -Root $canonicalSource)
    $destinationInventory = @(Get-CgceTreeInventory -Root $canonicalDestination)
    Compare-CgceInventory `
        -Expected $sourceInventory `
        -Actual $sourceAfterPublication
    Compare-CgceInventory `
        -Expected $sourceAfterPublication `
        -Actual $destinationInventory
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
    $sourceVolume = [System.IO.Path]::GetPathRoot($canonicalSource)
    $destinationVolume = [System.IO.Path]::GetPathRoot($canonicalDestination)
    if (-not $sourceVolume.Equals(
            $destinationVolume,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-OPS-PATH move requires equal volume roots"
    }
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

    $context = [pscustomobject]@{
        source = $canonicalSource
        destination = $canonicalDestination
    }
    Invoke-CgceTestPublishSeam -Phase "move-before-revalidate" -Context $context
    Assert-CgceNoReparseInPath -Path $canonicalSource
    Assert-CgceTreeHasNoReparsePoints -Root $canonicalSource
    Assert-CgceNoReparseInPath -Path $canonicalDestination
    Invoke-CgceTestPublishSeam -Phase "move-before-publish" -Context $context
    try {
        [System.IO.Directory]::Move($canonicalSource, $canonicalDestination)
    } catch {
        if (Test-Path -LiteralPath $canonicalDestination) {
            throw "CGCE-OPS-DESTINATION-EXISTS destination appeared before publication"
        }
        throw "CGCE-OPS-COPY directory rename failed"
    }
}

# This classifier is intentionally read-only. It freezes the initial
# production layout or validates a journal-bound resume position. It never
# creates a directory, inventory, receipt, or quarantine target.
function New-CgceFilesRecoveryAbsentState {
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $false
        length = $null
        sha256 = $null
        tree_sha256 = $null
    }
}

function New-CgceFilesRecoveryPresentState([string]$TreeSha256) {
    if ($TreeSha256 -cnotmatch '^[0-9a-f]{64}\z') {
        throw "CGCE-OPS-MANUAL-RECOVERY invalid directory tree checksum"
    }
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"
        present = $true
        length = $null
        sha256 = $null
        tree_sha256 = $TreeSha256
    }
}

function New-CgceFilesRecoveryDirectoryState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return New-CgceFilesRecoveryAbsentState
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery artifact is not a directory"
    }
    Assert-CgceNoReparseInPath -Path $Path
    Assert-CgceTreeHasNoReparsePoints -Root $Path
    $entries = @(Get-CgceTreeInventory -Root $Path)
    return New-CgceFilesRecoveryPresentState `
        (Get-CgceInventoryTreeSha256 -Entries $entries)
}

function Assert-CgceFilesRecoveryExactKeys(
    $Value,
    [string[]]$Expected
) {
    if ($null -eq $Value -or $Value -is [string]) {
        throw "CGCE-OPS-MANUAL-RECOVERY object required"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Expected.Count) {
        throw "CGCE-OPS-MANUAL-RECOVERY exact key set required"
    }
    for ($index = 0; $index -lt $Expected.Count; $index += 1) {
        if ($actual[$index] -cne $Expected[$index]) {
            throw "CGCE-OPS-MANUAL-RECOVERY exact key order required"
        }
    }
}

function Test-CgceFilesRecoveryInteger(
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

function Test-CgceFilesRecoveryUtc($Value) {
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

function Test-CgceFilesRecoveryChecksum($Value) {
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}\z'
}

function Get-CgceFilesRecoveryTextSha256([string]$Text) {
    $encoding = New-Object Text.UTF8Encoding($false)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($encoding.GetBytes($Text))
        )).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Test-CgceFilesRecoveryNumericValue($Value) {
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

function Test-CgceFilesRecoveryEqual($Left, $Right) {
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
            if (-not (Test-CgceFilesRecoveryEqual `
                    @($Left)[$index] `
                    @($Right)[$index])) {
                return $false
            }
        }
        return $true
    }
    $leftNumber = Test-CgceFilesRecoveryNumericValue $Left
    $rightNumber = Test-CgceFilesRecoveryNumericValue $Right
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
            -not (Test-CgceFilesRecoveryEqual `
                $Left.($leftNames[$index]) `
                $Right.($rightNames[$index]))) {
            return $false
        }
    }
    return $true
}

function Test-CgceFilesRecoveryPathEqual(
    [string]$Left,
    [string]$Right
) {
    $canonicalLeft = Resolve-CgceCanonicalPath -Path $Left -MustExist $false
    $canonicalRight = Resolve-CgceCanonicalPath -Path $Right -MustExist $false
    return $canonicalLeft.Equals(
        $canonicalRight,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-CgceFilesRecoveryArtifact($Value) {
    Assert-CgceFilesRecoveryExactKeys $Value @(
        "artifact_type", "present", "length", "sha256", "tree_sha256"
    )
    if ($Value.artifact_type -cne "DIRECTORY" -or
        $Value.present -isnot [bool] -or
        $null -ne $Value.length -or
        $null -ne $Value.sha256 -or
        ($Value.present -and
            -not (Test-CgceFilesRecoveryChecksum $Value.tree_sha256)) -or
        (-not $Value.present -and $null -ne $Value.tree_sha256)) {
        throw "CGCE-OPS-MANUAL-RECOVERY invalid recovery artifact state"
    }
}

function Assert-CgceFilesRecoveryStatePair($Pair) {
    Assert-CgceFilesRecoveryExactKeys $Pair @("source", "destination")
    Assert-CgceFilesRecoveryArtifact $Pair.source
    Assert-CgceFilesRecoveryArtifact $Pair.destination
}

function Assert-CgceFilesRecoveryErrorArray($Errors) {
    if ($Errors -isnot [System.Array]) {
        throw "CGCE-OPS-MANUAL-RECOVERY source errors must be an array"
    }
    foreach ($record in @($Errors)) {
        Assert-CgceFilesRecoveryExactKeys $record @("code", "at_utc")
        if ($record.code -isnot [string] -or
            $record.code -cnotmatch '^CGCE-OPS-[A-Z0-9-]+\z' -or
            -not (Test-CgceFilesRecoveryUtc $record.at_utc)) {
            throw "CGCE-OPS-MANUAL-RECOVERY invalid source error"
        }
    }
}

function New-CgceFilesRecoverySteps(
    $Paths,
    [string]$SelectedCase,
    $Original,
    $Clone,
    $Absent
) {
    switch ($SelectedCase) {
        "UNCHANGED_ORIGINAL" {
            return [object[]]@(
                [pscustomobject][ordered]@{
                    sequence = 10
                    step = "QUARANTINE_CLONE"
                    operation = "VERIFY_RESTORED"
                    source_path = $Paths.active_saved
                    destination_path = $Paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $Original; destination = $Absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Original; destination = $Absent
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "VERIFY_RESTORED"
                    source_path = $Paths.inactive_original
                    destination_path = $Paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Original
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Original
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
                    source_path = $Paths.active_saved
                    destination_path = $Paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Absent
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "MOVE_DIRECTORY"
                    source_path = $Paths.inactive_original
                    destination_path = $Paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $Original; destination = $Absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Original
                    }
                }
            )
        }
        "CLONE_AND_INACTIVE_ORIGINAL" {
            if ($null -eq $Clone) {
                throw "CGCE-OPS-MANUAL-RECOVERY clone authority is missing"
            }
            return [object[]]@(
                [pscustomobject][ordered]@{
                    sequence = 10
                    step = "QUARANTINE_CLONE"
                    operation = "MOVE_DIRECTORY"
                    source_path = $Paths.active_saved
                    destination_path = $Paths.quarantined_clone
                    before_state = [pscustomobject][ordered]@{
                        source = $Clone; destination = $Absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Clone
                    }
                },
                [pscustomobject][ordered]@{
                    sequence = 20
                    step = "RESTORE_ORIGINAL"
                    operation = "MOVE_DIRECTORY"
                    source_path = $Paths.inactive_original
                    destination_path = $Paths.active_saved
                    before_state = [pscustomobject][ordered]@{
                        source = $Original; destination = $Absent
                    }
                    after_state = [pscustomobject][ordered]@{
                        source = $Absent; destination = $Original
                    }
                }
            )
        }
        default {
            throw "CGCE-OPS-MANUAL-RECOVERY unsupported recovery case"
        }
    }
}

function Assert-CgceFilesRecoveryPaths($State) {
    foreach ($name in @(
            "active_saved", "inactive_original", "quarantined_clone"
        )) {
        $null = Resolve-CgceCanonicalPath `
            -Path $State.paths.$name `
            -MustExist $false
        Assert-CgceNoReparseInPath -Path $State.paths.$name
    }
    Assert-CgceDistinctRoots -Paths @(
        $State.paths.active_saved,
        $State.paths.inactive_original,
        $State.paths.quarantined_clone
    )
    $volume = $null
    foreach ($name in @(
            "active_saved", "inactive_original", "quarantined_clone"
        )) {
        $canonical = Resolve-CgceCanonicalPath `
            -Path $State.paths.$name `
            -MustExist $false
        $current = [IO.Path]::GetPathRoot($canonical)
        if ($null -eq $volume) {
            $volume = $current
        } elseif (-not $volume.Equals(
                $current,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "CGCE-OPS-MANUAL-RECOVERY recovery move crosses volumes"
        }
    }
}

function Get-CgceFilesRecoveryInventoryState(
    $State,
    [string]$Name,
    [bool]$RequireStateChecksum
) {
    $path = $State.paths.($Name + "_inventory")
    $entries = @(Read-CgceInventory -Path $path -ExpectedKind $Name)
    $checksum = Get-CgceSha256 -Path $path
    $recorded = $State.inventory_checksums.$Name
    if (($RequireStateChecksum -and
            -not (Test-CgceFilesRecoveryChecksum $recorded)) -or
        ($null -ne $recorded -and $checksum -cne $recorded)) {
        throw "CGCE-OPS-MANUAL-RECOVERY inventory checksum drift"
    }
    return New-CgceFilesRecoveryPresentState `
        (Get-CgceInventoryTreeSha256 -Entries $entries)
}

function Test-CgceFilesRecoveryCaseAllowed(
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

function Assert-CgceFilesRecoveryRestoringPreimage($State, $Intent) {
    $sourceRevision = [int64]$Intent.source_revision
    $currentRevision = [int64]$State.revision
    $legal = $false
    if ($currentRevision -eq $sourceRevision + 1 -and
        $State.outcome -ceq $Intent.source_outcome -and
        (Test-CgceFilesRecoveryEqual $State.errors $Intent.source_errors)) {
        $legal = $true
    } elseif ($currentRevision -eq $sourceRevision + 2 -and
        $State.outcome -ceq "BLOCKED") {
        $sourceErrors = @($Intent.source_errors)
        $currentErrors = @($State.errors)
        if ($currentErrors.Count -eq $sourceErrors.Count + 1) {
            $legal = $true
            for ($index = 0; $index -lt $sourceErrors.Count; $index += 1) {
                if (-not (Test-CgceFilesRecoveryEqual `
                        $sourceErrors[$index] `
                        $currentErrors[$index])) {
                    $legal = $false
                }
            }
            if ($legal) {
                Assert-CgceFilesRecoveryExactKeys `
                    $currentErrors[-1] `
                    @("code", "at_utc")
                if ($currentErrors[-1].code -cnotmatch
                        '^CGCE-OPS-[A-Z0-9-]+\z' -or
                    -not (Test-CgceFilesRecoveryUtc `
                        $currentErrors[-1].at_utc)) {
                    $legal = $false
                }
            }
        }
    }
    if (-not $legal) {
        throw "CGCE-OPS-MANUAL-RECOVERY RESTORING state delta drift"
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
    $matched = $false
    foreach ($text in @(
            ($preimage | ConvertTo-Json -Depth 12),
            ($preimage | ConvertTo-Json -Depth 12 -Compress)
        )) {
        if ((Get-CgceFilesRecoveryTextSha256 $text) -ceq
            $Intent.source_state_sha256) {
            $matched = $true
        }
    }
    if (-not $matched) {
        throw "CGCE-OPS-MANUAL-RECOVERY source preimage checksum drift"
    }
}

function Assert-CgceFilesRecoveryIntentShape(
    $State,
    $Intent,
    $Original,
    $Clone
) {
    Assert-CgceFilesRecoveryExactKeys $Intent @(
        "schema_version", "kind", "run_id", "sequence", "created_at_utc",
        "source_state_sha256", "source_phase", "source_outcome",
        "source_revision", "source_updated_at_utc", "source_errors",
        "genesis_state_sha256", "original_inventory_sha256",
        "original_tree_sha256", "selected_case", "paths", "steps"
    )
    if ($Intent.schema_version -cne "1.0" -or
        $Intent.kind -cne "cgce_windows_discovery_restore_intent" -or
        $Intent.run_id -cne $State.run_id -or
        -not (Test-CgceFilesRecoveryInteger $Intent.sequence 0 0) -or
        -not (Test-CgceFilesRecoveryUtc $Intent.created_at_utc) -or
        -not (Test-CgceFilesRecoveryUtc $Intent.source_updated_at_utc) -or
        -not (Test-CgceFilesRecoveryChecksum `
            $Intent.source_state_sha256) -or
        -not (Test-CgceFilesRecoveryChecksum `
            $Intent.genesis_state_sha256) -or
        -not (Test-CgceFilesRecoveryChecksum `
            $Intent.original_inventory_sha256) -or
        -not (Test-CgceFilesRecoveryChecksum `
            $Intent.original_tree_sha256) -or
        -not (Test-CgceFilesRecoveryInteger `
            $Intent.source_revision 0 ([int64]::MaxValue)) -or
        @("ACTIVE", "BLOCKED") -cnotcontains $Intent.source_outcome -or
        -not (Test-CgceFilesRecoveryCaseAllowed `
            $Intent.source_phase `
            $Intent.selected_case)) {
        throw "CGCE-OPS-MANUAL-RECOVERY invalid recovery intent"
    }
    Assert-CgceFilesRecoveryErrorArray $Intent.source_errors

    Assert-CgceFilesRecoveryExactKeys $Intent.paths @(
        "active_saved", "inactive_original", "quarantined_clone",
        "original_inventory", "restored_inventory", "restore_receipts",
        "probe_restore_final_receipt"
    )
    foreach ($name in @(
            "active_saved", "inactive_original", "quarantined_clone",
            "original_inventory", "restored_inventory", "restore_receipts"
        )) {
        if ($Intent.paths.$name -isnot [string] -or
            -not (Test-CgceFilesRecoveryPathEqual `
                $Intent.paths.$name `
                $State.paths.$name)) {
            throw "CGCE-OPS-MANUAL-RECOVERY intent path mismatch"
        }
    }
    $expectedProbeFinal = Join-Path `
        (Join-Path $State.paths.probe_receipts "restore") `
        "999-probe-restore-final.json"
    if (-not (Test-CgceFilesRecoveryPathEqual `
            $Intent.paths.probe_restore_final_receipt `
            $expectedProbeFinal)) {
        throw "CGCE-OPS-MANUAL-RECOVERY probe final path mismatch"
    }

    if ((Get-CgceSha256 $State.paths.genesis_state) -cne
            $Intent.genesis_state_sha256 -or
        $State.inventory_checksums.original -cne
            $Intent.original_inventory_sha256 -or
        $Original.tree_sha256 -cne $Intent.original_tree_sha256) {
        throw "CGCE-OPS-MANUAL-RECOVERY immutable recovery authority drift"
    }

    if ($State.phase -ceq $Intent.source_phase) {
        if ((Get-CgceSha256 $State.paths.state) -cne
                $Intent.source_state_sha256 -or
            $State.outcome -cne $Intent.source_outcome -or
            [int64]$State.revision -ne [int64]$Intent.source_revision -or
            $State.updated_at_utc -cne $Intent.source_updated_at_utc -or
            -not (Test-CgceFilesRecoveryEqual `
                $State.errors `
                $Intent.source_errors)) {
            throw "CGCE-OPS-MANUAL-RECOVERY source state authority drift"
        }
    } elseif ($State.phase -ceq "RESTORING") {
        Assert-CgceFilesRecoveryRestoringPreimage $State $Intent
    } else {
        throw "CGCE-OPS-MANUAL-RECOVERY state/intent phase drift"
    }

    if ($Intent.steps -isnot [System.Array] -or
        @($Intent.steps).Count -ne 2) {
        throw "CGCE-OPS-MANUAL-RECOVERY fixed recovery steps required"
    }
    foreach ($step in @($Intent.steps)) {
        Assert-CgceFilesRecoveryExactKeys $step @(
            "sequence", "step", "operation", "source_path",
            "destination_path", "before_state", "after_state"
        )
        Assert-CgceFilesRecoveryStatePair $step.before_state
        Assert-CgceFilesRecoveryStatePair $step.after_state
    }
    $absent = New-CgceFilesRecoveryAbsentState
    $expected = @(New-CgceFilesRecoverySteps `
        $State.paths `
        $Intent.selected_case `
        $Original `
        $Clone `
        $absent)
    for ($index = 0; $index -lt 2; $index += 1) {
        if (-not (Test-CgceFilesRecoveryEqual `
                $expected[$index] `
                @($Intent.steps)[$index])) {
            throw "CGCE-OPS-MANUAL-RECOVERY intent step authority drift"
        }
    }
    return [object[]]$expected
}

function Assert-CgceFilesRecoveryReceiptPrefix(
    $State,
    $Intent
) {
    $root = $State.paths.restore_receipts
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "CGCE-OPS-MANUAL-RECOVERY restore receipt root missing"
    }
    $allowed = @(
        "000-restore-intent.json",
        "010-quarantine-clone.json",
        "020-restore-original.json",
        "999-restore-final.json"
    )
    foreach ($child in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($child.PSIsContainer -or
            $allowed -cnotcontains $child.Name) {
            throw "CGCE-OPS-MANUAL-RECOVERY foreign recovery receipt"
        }
    }

    $intentPath = Join-Path $root "000-restore-intent.json"
    if (-not (Test-Path -LiteralPath $intentPath -PathType Leaf)) {
        throw "CGCE-OPS-MANUAL-RECOVERY missing recovery intent"
    }
    $onDisk = Read-CgceJsonObject $intentPath
    if (-not (Test-CgceFilesRecoveryEqual $onDisk $Intent)) {
        throw "CGCE-OPS-MANUAL-RECOVERY intent file mismatch"
    }

    $path010 = Join-Path $root "010-quarantine-clone.json"
    $path020 = Join-Path $root "020-restore-original.json"
    $path999 = Join-Path $root "999-restore-final.json"
    $has010 = Test-Path -LiteralPath $path010 -PathType Leaf
    $has020 = Test-Path -LiteralPath $path020 -PathType Leaf
    $has999 = Test-Path -LiteralPath $path999 -PathType Leaf
    if (($has020 -and -not $has010) -or
        ($has999 -and -not ($has010 -and $has020))) {
        throw "CGCE-OPS-MANUAL-RECOVERY recovery receipt sequence gap"
    }

    $previous = Get-CgceSha256 $intentPath
    $bindings = New-Object 'Collections.Generic.List[object]'
    foreach ($index in 0, 1) {
        $exists = if ($index -eq 0) { $has010 } else { $has020 }
        if (-not $exists) { continue }
        $step = @($Intent.steps)[$index]
        $path = if ($index -eq 0) { $path010 } else { $path020 }
        $receipt = Read-CgceJsonObject $path
        Assert-CgceFilesRecoveryExactKeys $receipt @(
            "schema_version", "kind", "run_id", "sequence", "step",
            "operation", "source_path", "destination_path",
            "before_state", "after_state", "previous_receipt_sha256",
            "completed_at_utc"
        )
        if ($receipt.schema_version -cne "1.0" -or
            $receipt.kind -cne
                "cgce_windows_discovery_restore_operation" -or
            $receipt.run_id -cne $State.run_id -or
            -not (Test-CgceFilesRecoveryInteger `
                $receipt.sequence `
                ([int64]$step.sequence) `
                ([int64]$step.sequence)) -or
            -not (Test-CgceFilesRecoveryUtc `
                $receipt.completed_at_utc) -or
            $receipt.previous_receipt_sha256 -cne $previous -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.step $step.step) -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.operation $step.operation) -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.source_path $step.source_path) -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.destination_path $step.destination_path) -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.before_state $step.before_state) -or
            -not (Test-CgceFilesRecoveryEqual `
                $receipt.after_state $step.after_state)) {
            throw "CGCE-OPS-MANUAL-RECOVERY recovery receipt authority drift"
        }
        $previous = Get-CgceSha256 $path
        $null = $bindings.Add([pscustomobject][ordered]@{
            sequence = [int]$step.sequence
            path = $path
            sha256 = $previous
        })
    }

    if ($has999) {
        $final = Read-CgceJsonObject $path999
        Assert-CgceFilesRecoveryExactKeys $final @(
            "schema_version", "kind", "run_id", "sequence",
            "restore_intent_sha256", "previous_receipt_sha256",
            "operation_receipts", "probe_restore_final_receipt",
            "original_inventory", "restored_inventory",
            "completed_at_utc"
        )
        if ($final.schema_version -cne "1.0" -or
            $final.kind -cne
                "cgce_windows_discovery_restore_final" -or
            $final.run_id -cne $State.run_id -or
            -not (Test-CgceFilesRecoveryInteger `
                $final.sequence 999 999) -or
            $final.restore_intent_sha256 -cne
                (Get-CgceSha256 $intentPath) -or
            $final.previous_receipt_sha256 -cne $previous -or
            -not (Test-CgceFilesRecoveryUtc $final.completed_at_utc) -or
            -not (Test-CgceFilesRecoveryEqual `
                $final.operation_receipts `
                ([object[]]$bindings.ToArray()))) {
            throw "CGCE-OPS-MANUAL-RECOVERY final recovery receipt drift"
        }
    }
    return [pscustomobject]@{
        has010 = $has010
        has020 = $has020
        has999 = $has999
    }
}

function Get-CgceFilesRecoveryLiveLayout($Paths) {
    return [pscustomobject][ordered]@{
        active_saved = (
            New-CgceFilesRecoveryDirectoryState $Paths.active_saved
        )
        inactive_original = (
            New-CgceFilesRecoveryDirectoryState $Paths.inactive_original
        )
        quarantined_clone = (
            New-CgceFilesRecoveryDirectoryState $Paths.quarantined_clone
        )
    }
}

function Get-CgceFilesRecoveryExpectedLayout(
    [string]$SelectedCase,
    [ValidateSet("INITIAL", "AFTER_010", "AFTER_020")]
    [string]$Position,
    $Original,
    $Clone,
    $Absent
) {
    if ($SelectedCase -ceq "UNCHANGED_ORIGINAL") {
        return [pscustomobject][ordered]@{
            active_saved = $Original
            inactive_original = $Absent
            quarantined_clone = $Absent
        }
    }
    if ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        if ($Position -ceq "AFTER_020") {
            return [pscustomobject][ordered]@{
                active_saved = $Original
                inactive_original = $Absent
                quarantined_clone = $Absent
            }
        }
        return [pscustomobject][ordered]@{
            active_saved = $Absent
            inactive_original = $Original
            quarantined_clone = $Absent
        }
    }
    if ($SelectedCase -ceq "CLONE_AND_INACTIVE_ORIGINAL") {
        if ($Position -ceq "INITIAL") {
            return [pscustomobject][ordered]@{
                active_saved = $Clone
                inactive_original = $Original
                quarantined_clone = $Absent
            }
        }
        if ($Position -ceq "AFTER_010") {
            return [pscustomobject][ordered]@{
                active_saved = $Absent
                inactive_original = $Original
                quarantined_clone = $Clone
            }
        }
        return [pscustomobject][ordered]@{
            active_saved = $Original
            inactive_original = $Absent
            quarantined_clone = $Clone
        }
    }
    throw "CGCE-OPS-MANUAL-RECOVERY unsupported recovery case"
}

function Assert-CgceFilesRecoveryResumeLayout(
    $State,
    $Intent,
    $Prefix,
    $Original,
    $Clone,
    $Absent
) {
    $positions = if (-not $Prefix.has010) {
        @("INITIAL", "AFTER_010")
    } elseif (-not $Prefix.has020) {
        @("AFTER_010", "AFTER_020")
    } else {
        @("AFTER_020")
    }
    $live = Get-CgceFilesRecoveryLiveLayout $State.paths
    $matched = $false
    foreach ($position in $positions) {
        $expected = Get-CgceFilesRecoveryExpectedLayout `
            $Intent.selected_case `
            $position `
            $Original `
            $Clone `
            $Absent
        if (Test-CgceFilesRecoveryEqual $live $expected) {
            $matched = $true
        }
    }
    if (-not $matched) {
        throw "CGCE-OPS-MANUAL-RECOVERY live recovery layout is not intent-bound"
    }
}

function Assert-CgceRecoveryMatrix($State, $Intent = $null) {
    try {
        if ($null -eq $State -or
            $null -eq $State.paths -or
            $null -eq $State.inventory_checksums) {
            throw "CGCE-OPS-MANUAL-RECOVERY invalid state"
        }
        Assert-CgceFilesRecoveryPaths $State
        $original = Get-CgceFilesRecoveryInventoryState `
            $State `
            "original" `
            $true
        $absent = New-CgceFilesRecoveryAbsentState

        if ($null -ne $Intent) {
            $clone = $null
            if ($Intent.selected_case -ceq
                "CLONE_AND_INACTIVE_ORIGINAL") {
                $clone = Get-CgceFilesRecoveryInventoryState `
                    $State `
                    "clone" `
                    ($null -ne $State.inventory_checksums.clone)
            }
            $steps = @(Assert-CgceFilesRecoveryIntentShape `
                $State `
                $Intent `
                $original `
                $clone)
            $prefix = Assert-CgceFilesRecoveryReceiptPrefix `
                $State `
                $Intent
            Assert-CgceFilesRecoveryResumeLayout `
                $State `
                $Intent `
                $prefix `
                $original `
                $clone `
                $absent
            return [pscustomobject][ordered]@{
                selected_case = $Intent.selected_case
                steps = [object[]]$steps
            }
        }

        if (Test-Path -LiteralPath $State.paths.restore_receipts -PathType Container) {
            $existingReceipts = @(
                Get-ChildItem `
                    -LiteralPath $State.paths.restore_receipts `
                    -Force
            )
            if ($existingReceipts.Count -gt 0) {
                throw "CGCE-OPS-MANUAL-RECOVERY existing receipts require an explicit intent"
            }
        }

        $live = Get-CgceFilesRecoveryLiveLayout $State.paths
        if ($live.quarantined_clone.present) {
            throw "CGCE-OPS-MANUAL-RECOVERY quarantine target is occupied"
        }
        $selectedCase = $null
        $clone = $null
        if ((Test-CgceFilesRecoveryEqual `
                $live.active_saved `
                $original) -and
            -not $live.inactive_original.present) {
            $selectedCase = "UNCHANGED_ORIGINAL"
        } elseif (-not $live.active_saved.present -and
            (Test-CgceFilesRecoveryEqual `
                $live.inactive_original `
                $original)) {
            $selectedCase = "NO_ACTIVE_AND_INACTIVE_ORIGINAL"
        } elseif ($live.active_saved.present -and
            (Test-CgceFilesRecoveryEqual `
                $live.inactive_original `
                $original) -and
            $live.active_saved.tree_sha256 -cne
                $original.tree_sha256) {
            $clone = Get-CgceFilesRecoveryInventoryState `
                $State `
                "clone" `
                ($null -ne $State.inventory_checksums.clone)
            if (-not (Test-CgceFilesRecoveryEqual `
                    $live.active_saved `
                    $clone)) {
                throw "CGCE-OPS-MANUAL-RECOVERY live clone inventory drift"
            }
            $selectedCase = "CLONE_AND_INACTIVE_ORIGINAL"
        } else {
            throw "CGCE-OPS-MANUAL-RECOVERY ambiguous recovery layout"
        }
        if (-not (Test-CgceFilesRecoveryCaseAllowed `
                $State.phase `
                $selectedCase)) {
            throw "CGCE-OPS-MANUAL-RECOVERY phase/layout recovery authority mismatch"
        }
        $steps = @(New-CgceFilesRecoverySteps `
            $State.paths `
            $selectedCase `
            $original `
            $clone `
            $absent)
        return [pscustomobject][ordered]@{
            selected_case = $selectedCase
            steps = [object[]]$steps
        }
    } catch {
        if ($_.Exception.Message -cmatch
            '^CGCE-OPS-MANUAL-RECOVERY(?: |\z)') {
            throw
        }
        throw "CGCE-OPS-MANUAL-RECOVERY recovery matrix authority rejected"
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
    "Initialize-CgceRunLayout",
    "Assert-CgceDiscoveryDiskCapacity",
    "Get-CgceTreeInventory",
    "Compare-CgceInventory",
    "Write-CgceInventory",
    "Read-CgceInventory",
    "Copy-CgceFileVerified",
    "Copy-CgceTreeVerified",
    "Move-CgceDirectoryNoOverwrite",
    "Assert-CgceRecoveryMatrix"
)
