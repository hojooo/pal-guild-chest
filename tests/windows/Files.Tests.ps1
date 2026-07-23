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

function Set-CgceFilesTestPublishSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Files"
    & $module {
        param($Value)
        $script:CgceTestPublishSeam = $Value
    } $Seam
}

function Set-CgceFilesTestRobocopySeam($Seam) {
    $module = Get-Module "CgceDiscovery.Files"
    & $module {
        param($Value)
        $script:CgceTestRobocopySeam = $Value
    } $Seam
}

function Set-CgceFilesTestLayoutSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Files"
    & $module {
        param($Value)
        $script:CgceTestLayoutSeam = $Value
    } $Seam
}

function Set-CgceFilesTestFreeSpaceSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Files"
    & $module {
        param($Value)
        $script:CgceTestFreeSpaceSeam = $Value
    } $Seam
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

Invoke-CgceTest "run layout publishes the exact fixed directories without changing the 41-key paths" {
    $root = New-CgceFilesTestRoot
    try {
        $serverRoot = Join-Path $root "server"
        $savedPath = Join-Path $serverRoot "Pal\Saved"
        $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
        $runRoot = Join-Path $root "runs"
        New-Item -ItemType Directory -Path $savedPath -Force | Out-Null
        New-Item -ItemType Directory -Path $ue4ssRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $paths = New-CgceRunPaths `
            -ServerRoot $serverRoot -SavedPath $savedPath `
            -Ue4ssRoot $ue4ssRoot -RunRoot $runRoot `
            -RunId "r-0123456789abcdef0123456789abcdef"

        Initialize-CgceRunLayout -Paths $paths

        Assert-CgceEqual 41 @($paths.PSObject.Properties).Count
        Assert-CgceEqual $true (Test-Path -LiteralPath $paths.run_directory -PathType Container)
        $relativeDirectories = @(
            Get-ChildItem -LiteralPath $paths.run_directory -Directory -Recurse |
                ForEach-Object {
                    $_.FullName.Substring($paths.run_directory.Length + 1)
                } |
                Sort-Object
        )
        $expected = @(
            "backup",
            "before",
            "capture",
            "inventories",
            "receipts",
            "receipts\probe",
            "receipts\process",
            "receipts\restore"
        ) | Sort-Object
        Assert-CgceEqual `
            ([string]::Join(",", $expected)) `
            ([string]::Join(",", $relativeDirectories))
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath (Join-Path $runRoot ".r-0123456789abcdef0123456789abcdef.cgce-stage-layout"))
        Assert-CgceThrows "CGCE-OPS-STATE-EXISTS" {
            Initialize-CgceRunLayout -Paths $paths
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run layout rejects fixed staging and preserves staging on publication failure" {
    $root = New-CgceFilesTestRoot
    try {
        $serverRoot = Join-Path $root "server"
        $savedPath = Join-Path $serverRoot "Pal\Saved"
        $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
        $runRoot = Join-Path $root "runs"
        New-Item -ItemType Directory -Path $savedPath -Force | Out-Null
        New-Item -ItemType Directory -Path $ue4ssRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $runId = "r-0123456789abcdef0123456789abcdef"
        $paths = New-CgceRunPaths `
            -ServerRoot $serverRoot -SavedPath $savedPath `
            -Ue4ssRoot $ue4ssRoot -RunRoot $runRoot -RunId $runId
        $staging = Join-Path $runRoot ".$runId.cgce-stage-layout"
        New-Item -ItemType Directory -Path $staging | Out-Null
        Assert-CgceThrows "CGCE-OPS-STATE-EXISTS" {
            Initialize-CgceRunLayout -Paths $paths
        }
        Remove-Item -LiteralPath $staging -Recurse -Force

        Set-CgceFilesTestLayoutSeam {
            param($Phase, $Context)
            if ($Phase -ceq "before-publish") {
                throw "injected layout failure"
            }
        }
        Assert-CgceThrows "CGCE-OPS-BLOCKED" {
            Initialize-CgceRunLayout -Paths $paths
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath $staging -PathType Container)
        Assert-CgceEqual $false (Test-Path -LiteralPath $paths.run_directory)
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $staging "receipts\restore"))
    } finally {
        Set-CgceFilesTestLayoutSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "run layout atomically claims fixed staging without merge and preserves race evidence" {
    $root = New-CgceFilesTestRoot
    try {
        $serverRoot = Join-Path $root "server"
        $savedPath = Join-Path $serverRoot "Pal\Saved"
        $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
        $runRoot = Join-Path $root "runs"
        New-Item -ItemType Directory -Path $savedPath -Force | Out-Null
        New-Item -ItemType Directory -Path $ue4ssRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $runId = "r-0123456789abcdef0123456789abcdef"
        $paths = New-CgceRunPaths `
            -ServerRoot $serverRoot -SavedPath $savedPath `
            -Ue4ssRoot $ue4ssRoot -RunRoot $runRoot -RunId $runId
        $fixed = Join-Path $runRoot ".$runId.cgce-stage-layout"
        Set-CgceFilesTestLayoutSeam {
            param($Phase, $Context)
            if ($Phase -ceq "before-claim") {
                $null = [System.IO.Directory]::CreateDirectory(
                    $Context.fixed_staging
                )
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.fixed_staging "competitor.txt"),
                    "competitor",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-STATE-EXISTS" {
            Initialize-CgceRunLayout -Paths $paths
        }
        Assert-CgceEqual `
            "competitor" `
            ([System.IO.File]::ReadAllText(
                (Join-Path $fixed "competitor.txt")
            ))
        Assert-CgceEqual $false (Test-Path -LiteralPath $paths.run_directory)
        $losing = @(
            Get-ChildItem `
                -LiteralPath $runRoot `
                -Directory `
                -Filter ".$runId.cgce-stage-layout-*"
        )
        Assert-CgceEqual 1 $losing.Count
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath (
                Join-Path $losing[0].FullName "receipts\restore"
            ))

        Remove-Item -LiteralPath $fixed -Recurse -Force
        Remove-Item -LiteralPath $losing[0].FullName -Recurse -Force
        Set-CgceFilesTestLayoutSeam {
            param($Phase, $Context)
            if ($Phase -ceq "after-claim") {
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.fixed_staging "unexpected.txt"),
                    "preserve",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-BLOCKED" {
            Initialize-CgceRunLayout -Paths $paths
        }
        Assert-CgceEqual `
            "preserve" `
            ([System.IO.File]::ReadAllText(
                (Join-Path $fixed "unexpected.txt")
            ))
        Assert-CgceEqual $false (Test-Path -LiteralPath $paths.run_directory)

        Remove-Item -LiteralPath $fixed -Recurse -Force
        Set-CgceFilesTestLayoutSeam {
            param($Phase, $Context)
            if ($Phase -ceq "before-publish") {
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.fixed_staging "late.txt"),
                    "late",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-BLOCKED" {
            Initialize-CgceRunLayout -Paths $paths
        }
        Assert-CgceEqual `
            "late" `
            ([System.IO.File]::ReadAllText((Join-Path $fixed "late.txt")))
        Assert-CgceEqual $false (Test-Path -LiteralPath $paths.run_directory)
    } finally {
        Set-CgceFilesTestLayoutSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "disk capacity aggregates checked inventory bytes by canonical volume" {
    $entries = @(
        [pscustomobject]@{ relative_path = "a"; length = [int64]7; sha256 = ("a" * 64) },
        [pscustomobject]@{ relative_path = "b"; length = [int64]5; sha256 = ("b" * 64) }
    )
    try {
        Set-CgceFilesTestFreeSpaceSeam {
            param($VolumeRoot)
            return [int64]24
        }
        Assert-CgceDiscoveryDiskCapacity `
            -Entries $entries `
            -BackupPath "C:\runs\r\backup\Saved" `
            -ClonePath "c:\server\Pal\Saved"

        Set-CgceFilesTestFreeSpaceSeam { param($VolumeRoot) return [int64]23 }
        Assert-CgceThrows "CGCE-OPS-DISK" {
            Assert-CgceDiscoveryDiskCapacity `
                -Entries $entries `
                -BackupPath "C:\runs\r\backup\Saved" `
                -ClonePath "C:\server\Pal\Saved"
        }

        Set-CgceFilesTestFreeSpaceSeam {
            param($VolumeRoot)
            if ($VolumeRoot -ceq "C:\") { return [int64]12 }
            if ($VolumeRoot -ceq "D:\") { return [int64]11 }
            return $null
        }
        Assert-CgceThrows "CGCE-OPS-DISK" {
            Assert-CgceDiscoveryDiskCapacity `
                -Entries $entries `
                -BackupPath "C:\runs\r\backup\Saved" `
                -ClonePath "D:\server\Pal\Saved"
        }
        Set-CgceFilesTestFreeSpaceSeam {
            param($VolumeRoot)
            if ($VolumeRoot -ceq "C:\") { return [int64]11 }
            if ($VolumeRoot -ceq "D:\") { return [int64]12 }
            return $null
        }
        Assert-CgceThrows "CGCE-OPS-DISK" {
            Assert-CgceDiscoveryDiskCapacity `
                -Entries $entries `
                -BackupPath "C:\runs\r\backup\Saved" `
                -ClonePath "D:\server\Pal\Saved"
        }

        Assert-CgceThrows "CGCE-OPS-DISK" {
            Assert-CgceDiscoveryDiskCapacity `
                -Entries @(
                    [pscustomobject]@{ relative_path = "a"; length = [int64]::MaxValue; sha256 = ("a" * 64) },
                    [pscustomobject]@{ relative_path = "b"; length = [int64]1; sha256 = ("b" * 64) }
                ) `
                -BackupPath "C:\runs\r\backup\Saved" `
                -ClonePath "D:\server\Pal\Saved"
        }
    } finally {
        Set-CgceFilesTestFreeSpaceSeam $null
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
        Assert-CgceEqual $true ($checksum -cmatch '^[0-9a-f]{64}\z')
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

Invoke-CgceTest "inventory checksum rejects valid prefixes followed by line endings" {
    foreach ($suffix in @("`n", "`r`n")) {
        $root = New-CgceFilesTestRoot
        try {
            $entries = @(
                [pscustomobject][ordered]@{
                    relative_path = "a.txt"
                    length = [int64]3
                    sha256 = ("a" * 64) + $suffix
                }
            )
            Assert-CgceThrows "CGCE-OPS-INVENTORY" {
                Write-CgceInventory `
                    -Entries $entries `
                    -Path (Join-Path $root "inventory.json") `
                    -Kind "original"
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
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

Invoke-CgceTest "verified file copy cannot overwrite a destination created before publication" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source.bin"
        $destination = Join-Path $root "destination.bin"
        Set-Content -LiteralPath $source -Value "source" -NoNewline
        Set-CgceFilesTestPublishSeam {
            param($Phase, $Context)
            if ($Phase -ceq "file-before-publish") {
                [System.IO.File]::WriteAllText(
                    $Context.destination,
                    "competitor",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Copy-CgceFileVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual "source" ([System.IO.File]::ReadAllText($source))
        Assert-CgceEqual "competitor" ([System.IO.File]::ReadAllText($destination))
        $staging = @(Get-ChildItem -LiteralPath $root -Filter ".destination.bin.cgce-stage-file-*")
        Assert-CgceEqual 1 $staging.Count
        Assert-CgceEqual "source" ([System.IO.File]::ReadAllText($staging[0].FullName))
    } finally {
        Set-CgceFilesTestPublishSeam $null
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

Invoke-CgceTest "verified tree copy cannot merge into a destination created before publication" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "source" -NoNewline
        Set-CgceFilesTestPublishSeam {
            param($Phase, $Context)
            if ($Phase -ceq "tree-before-publish") {
                [System.IO.Directory]::CreateDirectory($Context.destination) | Out-Null
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.destination "competitor.txt"),
                    "competitor",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $source "source.txt"))
        Assert-CgceEqual $false (Test-Path -LiteralPath (Join-Path $destination "source.txt"))
        Assert-CgceEqual `
            "competitor" `
            ([System.IO.File]::ReadAllText((Join-Path $destination "competitor.txt")))
        $staging = @(Get-ChildItem -LiteralPath $root -Directory -Filter ".destination.cgce-stage-tree-*")
        Assert-CgceEqual 1 $staging.Count
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $staging[0].FullName "source.txt"))
    } finally {
        Set-CgceFilesTestPublishSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy blocks source drift before publication" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "original" -NoNewline
        Set-CgceFilesTestPublishSeam {
            param($Phase, $Context)
            if ($Phase -ceq "tree-before-revalidate") {
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.source "source.txt"),
                    "drifted",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-INVENTORY" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual $false (Test-Path -LiteralPath $destination)
        Assert-CgceEqual "drifted" ([System.IO.File]::ReadAllText((Join-Path $source "source.txt")))
        $staging = @(Get-ChildItem -LiteralPath $root -Directory -Filter ".destination.cgce-stage-tree-*")
        Assert-CgceEqual 1 $staging.Count
        Assert-CgceEqual `
            "original" `
            ([System.IO.File]::ReadAllText((Join-Path $staging[0].FullName "source.txt")))
    } finally {
        Set-CgceFilesTestPublishSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy blocks source drift after publication" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "original" -NoNewline
        Set-CgceFilesTestPublishSeam {
            param($Phase, $Context)
            if ($Phase -ceq "tree-after-publish") {
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.source "source.txt"),
                    "drifted",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-INVENTORY" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual "drifted" ([System.IO.File]::ReadAllText((Join-Path $source "source.txt")))
        Assert-CgceEqual `
            "original" `
            ([System.IO.File]::ReadAllText((Join-Path $destination "source.txt")))
        $staging = @(Get-ChildItem -LiteralPath $root -Directory -Filter ".destination.cgce-stage-tree-*")
        Assert-CgceEqual 0 $staging.Count
    } finally {
        Set-CgceFilesTestPublishSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy preserves staging when robocopy fails" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "source" -NoNewline
        Set-CgceFilesTestRobocopySeam {
            param($Source, $Staging, $Arguments)
            if ([string]::Join(" ", $Arguments) -cne
                "/E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ") {
                throw "unexpected robocopy arguments"
            }
            [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $Staging "partial.txt"),
                "partial",
                (New-Object System.Text.UTF8Encoding($false))
            )
            return 8
        }
        Assert-CgceThrows "CGCE-OPS-COPY" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual $false (Test-Path -LiteralPath $destination)
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $source "source.txt"))
        $staging = @(Get-ChildItem -LiteralPath $root -Directory -Filter ".destination.cgce-stage-tree-*")
        Assert-CgceEqual 1 $staging.Count
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $staging[0].FullName "partial.txt"))
    } finally {
        Set-CgceFilesTestRobocopySeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "verified tree copy rejects a final-path junction before publication" {
    $root = New-CgceFilesTestRoot
    $destination = Join-Path $root "destination"
    try {
        $source = Join-Path $root "source"
        $outside = Join-Path $root "outside"
        New-Item -ItemType Directory -Path $source | Out-Null
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "source" -NoNewline
        $seam = {
            param($Phase, $Context)
            if ($Phase -ceq "tree-before-revalidate") {
                New-Item `
                    -ItemType Junction `
                    -Path $Context.destination `
                    -Target $outside | Out-Null
            }
        }.GetNewClosure()
        Set-CgceFilesTestPublishSeam $seam
        Assert-CgceThrows "CGCE-OPS-REPARSE" {
            Copy-CgceTreeVerified -Source $source -Destination $destination
        }
        Assert-CgceEqual $false (Test-Path -LiteralPath (Join-Path $outside "source.txt"))
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $source "source.txt"))
        $staging = @(Get-ChildItem -LiteralPath $root -Directory -Filter ".destination.cgce-stage-tree-*")
        Assert-CgceEqual 1 $staging.Count
    } finally {
        Set-CgceFilesTestPublishSeam $null
        if (Test-Path -LiteralPath $destination) {
            [System.IO.Directory]::Delete($destination)
        }
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

Invoke-CgceTest "directory move cannot nest beneath a destination created before publication" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        $destination = Join-Path $root "destination"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "source" -NoNewline
        Set-CgceFilesTestPublishSeam {
            param($Phase, $Context)
            if ($Phase -ceq "move-before-publish") {
                [System.IO.Directory]::CreateDirectory($Context.destination) | Out-Null
                [System.IO.File]::WriteAllText(
                    (Join-Path $Context.destination "competitor.txt"),
                    "competitor",
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        }
        Assert-CgceThrows "CGCE-OPS-DESTINATION-EXISTS" {
            Move-CgceDirectoryNoOverwrite -Source $source -Destination $destination
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $source "source.txt"))
        Assert-CgceEqual $false (Test-Path -LiteralPath (Join-Path $destination "source"))
        Assert-CgceEqual $false (Test-Path -LiteralPath (Join-Path $destination "source.txt"))
        Assert-CgceEqual `
            "competitor" `
            ([System.IO.File]::ReadAllText((Join-Path $destination "competitor.txt")))
    } finally {
        Set-CgceFilesTestPublishSeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "directory move rejects a different volume before touching source" {
    $root = New-CgceFilesTestRoot
    try {
        $source = Join-Path $root "source"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "source.txt") -Value "source" -NoNewline
        $sourceVolume = [System.IO.Path]::GetPathRoot($source)
        $otherVolume = if ($sourceVolume.StartsWith("C:", [StringComparison]::OrdinalIgnoreCase)) {
            "D:\"
        } else {
            "C:\"
        }
        $destination = [System.IO.Path]::Combine(
            $otherVolume,
            "cgce-cross-volume-" + [guid]::NewGuid().ToString("N")
        )
        Assert-CgceThrows "CGCE-OPS-PATH" {
            Move-CgceDirectoryNoOverwrite -Source $source -Destination $destination
        }
        Assert-CgceEqual $true (Test-Path -LiteralPath (Join-Path $source "source.txt"))
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
