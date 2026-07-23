Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Files.psm1" -Force

function New-CgceFilesTestRoot {
    $root = Join-Path $env:TEMP ("cgce-files-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

function Write-CgceFilesTestUtf8([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-CgceFilesTestSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Invoke-CgceTest "canonical paths preserve Windows volume roots and normalize descendants" {
    Assert-CgceEqual "D:\" (Resolve-CgceCanonicalPath -Path "D:\" -MustExist $false)
    Assert-CgceEqual `
        "D:\Pal\Saved" `
        (Resolve-CgceCanonicalPath -Path "D:\Pal\Saved" -MustExist $false)
    Assert-CgceEqual `
        "D:\Pal\Saved" `
        (Resolve-CgceCanonicalPath -Path "D:\Pal\Saved\\" -MustExist $false)
    Assert-CgceEqual `
        "\\server\share\" `
        (Resolve-CgceCanonicalPath -Path "\\server\share\" -MustExist $false)
    Assert-CgceEqualCanonicalPath -Expected "D:\PAL\Saved" -Actual "d:\pal\saved\"
}

Invoke-CgceTest "canonical paths reject missing required paths" {
    $missing = Join-Path $env:TEMP ("cgce-missing-" + [guid]::NewGuid().ToString("N"))
    Assert-CgceThrows "CGCE-OPS-PATH" {
        Resolve-CgceCanonicalPath -Path $missing -MustExist $true
    }
    Assert-CgceThrows "CGCE-OPS-PATH" {
        Resolve-CgceCanonicalPath -Path ".\relative" -MustExist $false
    }
}

Invoke-CgceTest "path containment uses component boundaries" {
    Assert-CgcePathContainedBy -Path "D:\Pal\Saved" -Root "d:\pal"
    Assert-CgcePathContainedBy -Path "D:\Pal" -Root "d:\pal\"
    Assert-CgceThrows "CGCE-OPS-PATH" {
        Assert-CgcePathContainedBy -Path "D:\PalOther" -Root "D:\Pal"
    }
}

Invoke-CgceTest "distinct roots reject equality and nesting but not prefix siblings" {
    Assert-CgceThrows "CGCE-OPS-PATH-OVERLAP" {
        Assert-CgceDistinctRoots -Paths @("D:\Pal", "d:\pal\")
    }
    Assert-CgceThrows "CGCE-OPS-PATH-OVERLAP" {
        Assert-CgceDistinctRoots -Paths @("D:\Pal", "D:\Pal\Saved")
    }
    Assert-CgceDistinctRoots -Paths @("D:\Pal", "D:\PalOther")
}

Invoke-CgceTest "path component scan rejects a junction before the target" {
    $root = New-CgceFilesTestRoot
    $junction = Join-Path $root "junction"
    try {
        $outside = Join-Path $root "outside"
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        Assert-CgceThrows "CGCE-OPS-REPARSE" {
            Assert-CgceNoReparseInPath -Path (Join-Path $junction "future\file.txt")
        }
    } finally {
        if (Test-Path -LiteralPath $junction) {
            [System.IO.Directory]::Delete($junction)
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "tree scan rejects a nested junction without traversing it" {
    $root = New-CgceFilesTestRoot
    $junction = Join-Path (Join-Path $root "source") "junction"
    try {
        $source = Join-Path $root "source"
        $outside = Join-Path $root "outside"
        New-Item -ItemType Directory -Path $source | Out-Null
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "outside.txt") -Value "outside" -NoNewline
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        Assert-CgceThrows "CGCE-OPS-REPARSE" {
            Assert-CgceTreeHasNoReparsePoints -Root $source
        }
    } finally {
        if (Test-Path -LiteralPath $junction) {
            [System.IO.Directory]::Delete($junction)
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "inventory is relative sorted and byte exact" {
    $root = New-CgceFilesTestRoot
    try {
        New-Item -ItemType Directory -Path (Join-Path $root "b") | Out-Null
        Set-Content -LiteralPath (Join-Path $root "b\2.txt") -Value "two" -NoNewline
        Set-Content -LiteralPath (Join-Path $root "1.txt") -Value "one" -NoNewline
        $items = @(Get-CgceTreeInventory -Root $root)
        Assert-CgceEqual 2 $items.Count
        Assert-CgceEqual "1.txt" $items[0].relative_path
        Assert-CgceEqual 3 $items[0].length
        Assert-CgceEqual (Get-CgceFilesTestSha256 (Join-Path $root "1.txt")) $items[0].sha256
        Assert-CgceEqual "b/2.txt" $items[1].relative_path
        Assert-CgceEqual 3 $items[1].length
        Assert-CgceEqual (Get-CgceFilesTestSha256 (Join-Path $root "b\2.txt")) $items[1].sha256
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "inventory comparison checks count path length and checksum" {
    $expected = @(
        [pscustomobject]@{
            relative_path = "a.txt"
            length = [int64]1
            sha256 = ("a" * 64)
        }
    )
    Compare-CgceInventory -Expected $expected -Actual @(
        [pscustomobject]@{
            relative_path = "a.txt"
            length = [int64]1
            sha256 = ("a" * 64)
        }
    )
    Assert-CgceThrows "CGCE-OPS-INVENTORY" {
        Compare-CgceInventory -Expected $expected -Actual @()
    }
    foreach ($changed in @(
        [pscustomobject]@{
            relative_path = "b.txt"
            length = [int64]1
            sha256 = ("a" * 64)
        },
        [pscustomobject]@{
            relative_path = "a.txt"
            length = [int64]2
            sha256 = ("a" * 64)
        },
        [pscustomobject]@{
            relative_path = "a.txt"
            length = [int64]1
            sha256 = ("b" * 64)
        }
    )) {
        Assert-CgceThrows "CGCE-OPS-INVENTORY" {
            Compare-CgceInventory -Expected $expected -Actual @($changed)
        }
    }
}

Invoke-CgceTest "run paths derive the exact contract key set without creating directories" {
    $runId = "r-0123456789abcdef0123456789abcdef"
    $paths = New-CgceRunPaths `
        -ServerRoot "D:\PalServer\" `
        -SavedPath "d:\palserver\Pal\Saved\\" `
        -Ue4ssRoot "D:\PalServer\Pal\Binaries\Win64\" `
        -RunRoot "E:\CGCE-Private-Runs\" `
        -RunId $runId
    $expectedKeys = @(
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
    $actualKeys = @($paths.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-CgceEqual ([string]::Join(",", $expectedKeys)) ([string]::Join(",", $actualKeys))
    Assert-CgceEqual "D:\PalServer" $paths.server_root
    Assert-CgceEqual "d:\palserver\Pal\Saved" $paths.active_saved
    Assert-CgceEqual `
        "d:\palserver\Pal\Saved.cgce-original-$runId" `
        $paths.inactive_original
    Assert-CgceEqual "d:\palserver\Pal\Saved.cgce-test-$runId" $paths.quarantined_clone
    Assert-CgceEqual "E:\CGCE-Private-Runs\$runId\run-state.json" $paths.state
    Assert-CgceEqual `
        "E:\CGCE-Private-Runs\$runId\receipts\restore" `
        $paths.restore_receipts
    Assert-CgceEqual `
        "E:\CGCE-Private-Runs\$runId\receipts\probe\000-probe-intent.json" `
        $paths.probe_intent
    Assert-CgceEqual `
        "D:\PalServer\Pal\Binaries\Win64\Mods\mods.txt.cgce-original-$runId" `
        $paths.mods_original
    Assert-CgceEqual `
        "D:\PalServer\Pal\Binaries\Win64\UE4SS_ObjectDump.txt.cgce-test-$runId" `
        $paths.object_dump_quarantine
}

Invoke-CgceTest "run paths reject invalid ids and non-exact Saved paths" {
    Assert-CgceThrows "CGCE-OPS-PATH" {
        New-CgceRunPaths `
            -ServerRoot "D:\PalServer" `
            -SavedPath "D:\PalServer\Pal\Saved" `
            -Ue4ssRoot "D:\PalServer\Pal\Binaries\Win64" `
            -RunRoot "E:\CGCE-Private-Runs" `
            -RunId "r-invalid"
    }
    Assert-CgceThrows "CGCE-OPS-PATH" {
        New-CgceRunPaths `
            -ServerRoot "D:\PalServer" `
            -SavedPath "D:\PalServer\Other\Saved" `
            -Ue4ssRoot "D:\PalServer\Pal\Binaries\Win64" `
            -RunRoot "E:\CGCE-Private-Runs" `
            -RunId "r-0123456789abcdef0123456789abcdef"
    }
}

Invoke-CgceTest "inventory envelope round trips one entry and returns its checksum" {
    $root = New-CgceFilesTestRoot
    try {
        $path = Join-Path $root "inventory.json"
        $entries = @(
            [pscustomobject][ordered]@{
                relative_path = "a.txt"
                length = [int64]3
                sha256 = ("a" * 64)
            }
        )
        $checksum = Write-CgceInventory -Entries $entries -Path $path -Kind "original"
        Assert-CgceEqual (Get-CgceFilesTestSha256 $path) $checksum
        Assert-CgceEqual $true ($checksum -cmatch '^[0-9a-f]{64}$')
        $read = @(Read-CgceInventory -Path $path -ExpectedKind "original")
        Assert-CgceEqual 1 $read.Count
        Assert-CgceEqual "a.txt" $read[0].relative_path
        Assert-CgceEqual 3 $read[0].length
        Assert-CgceEqual ("a" * 64) $read[0].sha256
        Assert-CgceThrows "CGCE-OPS-OUTPUT-EXISTS" {
            Write-CgceInventory -Entries $entries -Path $path -Kind "original"
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "inventory reader rejects malformed envelopes and entries" {
    $root = New-CgceFilesTestRoot
    try {
        $path = Join-Path $root "inventory.json"
        $valid = '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":1,"sha256":"' + ("a" * 64) + '"}]}'
        $invalidDocuments = @(
            '[]',
            '{"schema_version":"1.0","kind":"original","entries":[],"extra":true}',
            '{"schema_version":"2.0","kind":"original","entries":[]}',
            '{"schema_version":"1.0","kind":"backup","entries":[]}',
            '{"schema_version":"1.0","kind":"original","entries":{}}',
            '{"schema_version":"1.0","kind":"original","entries":[null]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"b.txt","length":1,"sha256":"' + ("b" * 64) + '"},{"relative_path":"a.txt","length":1,"sha256":"' + ("a" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":1,"sha256":"' + ("a" * 64) + '"},{"relative_path":"a.txt","length":1,"sha256":"' + ("a" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"../a.txt","length":1,"sha256":"' + ("a" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":-1,"sha256":"' + ("a" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":1.5,"sha256":"' + ("a" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":1,"sha256":"' + ("A" * 64) + '"}]}',
            '{"schema_version":"1.0","kind":"original","entries":[{"relative_path":"a.txt","length":1,"sha256":"' + ("a" * 64) + '","extra":true}]}'
        )
        foreach ($document in $invalidDocuments) {
            Write-CgceFilesTestUtf8 -Path $path -Text $document
            Assert-CgceThrows "CGCE-OPS-INVENTORY" {
                Read-CgceInventory -Path $path -ExpectedKind "original"
            }
        }
        Write-CgceFilesTestUtf8 -Path $path -Text $valid
        Assert-CgceEqual 1 @(Read-CgceInventory -Path $path -ExpectedKind "original").Count
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified file copy preserves bytes and never overwrites" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source.bin"
        $destination = Join-Path $root "destination.bin"
        [System.IO.File]::WriteAllBytes($source, [byte[]](0, 1, 2, 255))
        $record = Copy-CgceFileVerified -Source $source -Destination $destination
        Assert-CgceEqual 4 $record.length
        Assert-CgceEqual (Get-CgceFilesTestSha256 $source) $record.sha256
        Assert-CgceEqual (Get-CgceFilesTestSha256 $source) (Get-CgceFilesTestSha256 $destination)
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Copy-CgceFileVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual (Get-CgceFilesTestSha256 $source) (Get-CgceFilesTestSha256 $destination)
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified file copy rejects a missing source" {
    $root = New-CgceFilesTestRoot
    try {
        Assert-CgceThrows "CGCE-OPS-COPY" {
            Copy-CgceFileVerified `
                -Source (Join-Path $root "missing.bin") `
                -Destination (Join-Path $root "destination.bin")
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy returns an exact inventory and never overwrites" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path (Join-Path $source "nested") | Out-Null
        Set-Content -LiteralPath (Join-Path $source "a.txt") -Value "a" -NoNewline
        Set-Content -LiteralPath (Join-Path $source "nested\b.txt") -Value "bb" -NoNewline
        $expected = @(Get-CgceTreeInventory -Root $source)
        $actual = @(Copy-CgceTreeVerified -Source $source -Destination $destination)
        Compare-CgceInventory -Expected $expected -Actual $actual
        Set-Content -LiteralPath (Join-Path $destination "sentinel.txt") -Value "keep" -NoNewline
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual "keep" ([System.IO.File]::ReadAllText((Join-Path $destination "sentinel.txt")))
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy rejects overlapping roots" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        New-Item -ItemType Directory -Path $source | Out-Null
        Assert-CgceThrows "CGCE-OPS-PATH-OVERLAP" {
            Copy-CgceTreeVerified `
                -Source $source `
                -Destination (Join-Path $source "destination")
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "directory move is same-volume no-overwrite rename" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "original.txt") -Value "original" -NoNewline
        Move-CgceDirectoryNoOverwrite -Source $source -Destination $destination
        Assert-CgceEqual $false (Test-Path -LiteralPath $source)
        Assert-CgceEqual "original" ([System.IO.File]::ReadAllText((Join-Path $destination "original.txt")))

        $nextSource = Join-Path $root "next-source"
        New-Item -ItemType Directory -Path $nextSource | Out-Null
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Move-CgceDirectoryNoOverwrite -Source $nextSource -Destination $destination
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath $nextSource -PathType Container)
        Assert-CgceEqual "original" ([System.IO.File]::ReadAllText((Join-Path $destination "original.txt")))
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "filesystem module exports only approved interfaces" {
    $expected = @(
        "Assert-CgceDistinctRoots",
        "Assert-CgceEqualCanonicalPath",
        "Assert-CgceNoReparseInPath",
        "Assert-CgcePathContainedBy",
        "Assert-CgceTreeHasNoReparsePoints",
        "Compare-CgceInventory",
        "Copy-CgceFileVerified",
        "Copy-CgceTreeVerified",
        "Get-CgceTreeInventory",
        "Move-CgceDirectoryNoOverwrite",
        "New-CgceRunPaths",
        "Read-CgceInventory",
        "Resolve-CgceCanonicalPath",
        "Write-CgceInventory"
    )
    $module = Get-Module "CgceDiscovery.Files"
    $actual = @($module.ExportedFunctions.Keys)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    Assert-CgceEqual ([string]::Join(",", $expected)) ([string]::Join(",", $actual))
}

Invoke-CgceTest "common module exposes contract and filesystem interfaces" {
    Import-Module `
        "$PSScriptRoot\..\..\tools\windows-discovery\CgceDiscovery.Common.psm1" `
        -Force
    foreach ($name in @(
        "Read-CgceJsonObject",
        "Write-CgceJsonAtomic",
        "Resolve-CgceCanonicalPath",
        "New-CgceRunPaths",
        "Copy-CgceTreeVerified",
        "Move-CgceDirectoryNoOverwrite"
    )) {
        Assert-CgceEqual $true ($null -ne (Get-Command $name -ErrorAction SilentlyContinue))
    }
}
