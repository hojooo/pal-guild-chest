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
        "Assert-CgceRecoveryMatrix",
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

function ConvertTo-CgceFilesTestJson($Value) {
    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function New-CgceFilesArtifactState([string]$TreeSha256, [bool]$Present) {
    return [pscustomobject][ordered]@{
        artifact_type = "DIRECTORY"; present = $Present
        length = $null; sha256 = $null
        tree_sha256 = if ($Present) { $TreeSha256 } else { $null }
    }
}

function Assert-CgceFilesArtifactState($Expected, $Actual) {
    Assert-CgceEqual `
        "artifact_type,present,length,sha256,tree_sha256" `
        ([string]::Join(",", @($Actual.PSObject.Properties.Name)))
    foreach ($name in @("artifact_type", "present", "length", "sha256", "tree_sha256")) {
        Assert-CgceDeepEqual $Expected.$name $Actual.$name
    }
}

function Get-CgceFilesPhaseRevision([string]$Phase) {
    return [Array]::IndexOf(@(
        "CREATED", "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED",
        "CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED"
    ), $Phase)
}

function New-CgceFilesRecoveryFixture([string]$Phase, [string]$Layout) {
    $root = New-CgceFilesTestRoot
    $serverRoot = Join-Path $root "server"
    $runRoot = Join-Path $root "runs"
    $runId = "r-0123456789abcdef0123456789abcdef"
    $paths = New-CgceRunPaths `
        -ServerRoot $serverRoot `
        -SavedPath (Join-Path $serverRoot "Pal\Saved") `
        -Ue4ssRoot (Join-Path $serverRoot "Pal\Binaries\Win64") `
        -RunRoot $runRoot -RunId $runId
    foreach ($directory in @(
            $paths.run_directory, $paths.restore_receipts,
            (Split-Path -Parent $paths.original_inventory),
            (Split-Path -Parent $paths.active_saved)
        )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $originalSource = Join-Path $root "original-source"
    $cloneSource = Join-Path $root "clone-source"
    New-Item -ItemType Directory -Path $originalSource | Out-Null
    New-Item -ItemType Directory -Path $cloneSource | Out-Null
    Write-CgceFilesTestUtf8 (Join-Path $originalSource "World.sav") "original-world"
    Write-CgceFilesTestUtf8 (Join-Path $cloneSource "World.sav") "test-clone"
    $originalEntries = @(Get-CgceTreeInventory $originalSource)
    $cloneEntries = @(Get-CgceTreeInventory $cloneSource)
    $originalTree = Get-CgceInventoryTreeSha256 $originalEntries
    $cloneTree = Get-CgceInventoryTreeSha256 $cloneEntries
    if ($Layout -ceq "UNCHANGED_ORIGINAL") {
        $null = Copy-CgceTreeVerified $originalSource $paths.active_saved
    } elseif ($Layout -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        $null = Copy-CgceTreeVerified $originalSource $paths.inactive_original
    } elseif ($Layout -ceq "CLONE_AND_INACTIVE_ORIGINAL") {
        $null = Copy-CgceTreeVerified $cloneSource $paths.active_saved
        $null = Copy-CgceTreeVerified $originalSource $paths.inactive_original
    } else {
        throw "CGCE-TEST unknown recovery layout"
    }

    $genesis = New-CgceRunState $runId "m-0123456789abcdef0123456789abcdef" $paths
    $genesis.bundle_checksum = ("a" * 64)
    $genesis.control_evidence_checksum = ("b" * 64)
    $genesis.source_manifest_checksum = ("c" * 64)
    $genesis.palserver_executable = (Join-Path $serverRoot "PalServer.exe")
    $genesis.palserver_executable_checksum = ("d" * 64)
    $genesis.ue4ss_version = "3.0.1"
    $genesis.server_process_paths = @($genesis.palserver_executable)
    $genesis.ue4ss_dll_checksum = ("e" * 64)
    $genesis.listener_ports = @(49151)
    $genesis.inventory_checksums.original = Write-CgceInventory `
        $originalEntries $paths.original_inventory "original"
    $cloneInventorySha = $null
    if ($Layout -ceq "CLONE_AND_INACTIVE_ORIGINAL") {
        $cloneInventorySha = Write-CgceInventory `
            $cloneEntries $paths.clone_inventory "clone"
    }
    Write-CgceJsonAtomic $genesis $paths.genesis_state

    $state = Read-CgceJsonObject $paths.genesis_state
    $state.phase = $Phase
    $state.revision = Get-CgceFilesPhaseRevision $Phase
    if (@(
            "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED", "CLONE_ACTIVE",
            "PROBE_STAGED", "RUNNING", "CAPTURED"
        ) -contains $Phase) {
        $state.inventory_checksums.backup = Write-CgceInventory `
            $originalEntries $paths.backup_inventory "backup"
    }
    if (@("CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED") -contains $Phase) {
        if ($null -eq $cloneInventorySha) {
            $cloneInventorySha = Write-CgceInventory `
                $cloneEntries $paths.clone_inventory "clone"
        }
        $state.inventory_checksums.clone = $cloneInventorySha
    }
    if (@("PROBE_STAGED", "RUNNING", "CAPTURED") -contains $Phase) {
        $state.probe_receipt_checksum = ("4" * 64)
    }
    if ($Phase -ceq "CAPTURED") {
        $state.process_launch_receipt_checksum = ("5" * 64)
        $state.process_result_receipt_checksum = ("6" * 64)
        $state.capture_inventory_checksum = ("7" * 64)
    }
    Write-CgceJsonAtomic $state $paths.state
    return [pscustomobject]@{
        Root = $root; Paths = $paths; State = $state; Genesis = $genesis
        SelectedCase = $Layout
        Original = (New-CgceFilesArtifactState $originalTree $true)
        Clone = (New-CgceFilesArtifactState $cloneTree $true)
        Absent = (New-CgceFilesArtifactState "" $false)
        OriginalTree = $originalTree
    }
}

function New-CgceFilesExpectedSteps($Fixture, [string]$SelectedCase) {
    $paths = $Fixture.Paths
    if ($SelectedCase -ceq "UNCHANGED_ORIGINAL") {
        return @(
            [pscustomobject]@{
                Sequence = 10; Step = "QUARANTINE_CLONE"; Operation = "VERIFY_RESTORED"
                SourcePath = $paths.active_saved; DestinationPath = $paths.quarantined_clone
                BeforeSource = $Fixture.Original; BeforeDestination = $Fixture.Absent
                AfterSource = $Fixture.Original; AfterDestination = $Fixture.Absent
            },
            [pscustomobject]@{
                Sequence = 20; Step = "RESTORE_ORIGINAL"; Operation = "VERIFY_RESTORED"
                SourcePath = $paths.inactive_original; DestinationPath = $paths.active_saved
                BeforeSource = $Fixture.Absent; BeforeDestination = $Fixture.Original
                AfterSource = $Fixture.Absent; AfterDestination = $Fixture.Original
            }
        )
    }
    $firstOperation = if ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        "VERIFY_ABSENT"
    } else { "MOVE_DIRECTORY" }
    $firstSource = if ($SelectedCase -ceq "NO_ACTIVE_AND_INACTIVE_ORIGINAL") {
        $Fixture.Absent
    } else { $Fixture.Clone }
    return @(
        [pscustomobject]@{
            Sequence = 10; Step = "QUARANTINE_CLONE"; Operation = $firstOperation
            SourcePath = $paths.active_saved; DestinationPath = $paths.quarantined_clone
            BeforeSource = $firstSource; BeforeDestination = $Fixture.Absent
            AfterSource = $Fixture.Absent; AfterDestination = $firstSource
        },
        [pscustomobject]@{
            Sequence = 20; Step = "RESTORE_ORIGINAL"; Operation = "MOVE_DIRECTORY"
            SourcePath = $paths.inactive_original; DestinationPath = $paths.active_saved
            BeforeSource = $Fixture.Original; BeforeDestination = $Fixture.Absent
            AfterSource = $Fixture.Absent; AfterDestination = $Fixture.Original
        }
    )
}

function Assert-CgceFilesRecoveryMatrix($Fixture, $Matrix, [string]$SelectedCase) {
    Assert-CgceEqual "selected_case,steps" `
        ([string]::Join(",", @($Matrix.PSObject.Properties.Name)))
    Assert-CgceEqual $SelectedCase $Matrix.selected_case
    Assert-CgceEqual 2 @($Matrix.steps).Count
    $expected = @(New-CgceFilesExpectedSteps $Fixture $SelectedCase)
    for ($index = 0; $index -lt 2; $index += 1) {
        $actual = @($Matrix.steps)[$index]
        Assert-CgceEqual `
            "sequence,step,operation,source_path,destination_path,before_state,after_state" `
            ([string]::Join(",", @($actual.PSObject.Properties.Name)))
        Assert-CgceEqual "source,destination" `
            ([string]::Join(",", @($actual.before_state.PSObject.Properties.Name)))
        Assert-CgceEqual "source,destination" `
            ([string]::Join(",", @($actual.after_state.PSObject.Properties.Name)))
        Assert-CgceEqual $expected[$index].Sequence ([int]$actual.sequence)
        Assert-CgceEqual $expected[$index].Step $actual.step
        Assert-CgceEqual $expected[$index].Operation $actual.operation
        Assert-CgceEqual $expected[$index].SourcePath $actual.source_path
        Assert-CgceEqual $expected[$index].DestinationPath $actual.destination_path
        Assert-CgceFilesArtifactState $expected[$index].BeforeSource $actual.before_state.source
        Assert-CgceFilesArtifactState $expected[$index].BeforeDestination $actual.before_state.destination
        Assert-CgceFilesArtifactState $expected[$index].AfterSource $actual.after_state.source
        Assert-CgceFilesArtifactState $expected[$index].AfterDestination $actual.after_state.destination
    }
}

function New-CgceFilesRecoveryIntent($Fixture) {
    $steps = New-Object 'Collections.Generic.List[object]'
    foreach ($expected in @(New-CgceFilesExpectedSteps `
            $Fixture $Fixture.SelectedCase)) {
        $null = $steps.Add([pscustomobject][ordered]@{
            sequence = $expected.Sequence; step = $expected.Step
            operation = $expected.Operation
            source_path = $expected.SourcePath; destination_path = $expected.DestinationPath
            before_state = [pscustomobject][ordered]@{
                source = $expected.BeforeSource; destination = $expected.BeforeDestination
            }
            after_state = [pscustomobject][ordered]@{
                source = $expected.AfterSource; destination = $expected.AfterDestination
            }
        })
    }
    $state = $Fixture.State
    return [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_restore_intent"
        run_id = $state.run_id; sequence = 0
        created_at_utc = "2026-07-24T00:00:01Z"
        source_state_sha256 = (Get-CgceSha256 $Fixture.Paths.state)
        source_phase = $state.phase; source_outcome = $state.outcome
        source_revision = $state.revision; source_updated_at_utc = $state.updated_at_utc
        source_errors = $state.errors
        genesis_state_sha256 = (Get-CgceSha256 $Fixture.Paths.genesis_state)
        original_inventory_sha256 = $state.inventory_checksums.original
        original_tree_sha256 = $Fixture.OriginalTree
        selected_case = $Fixture.SelectedCase
        paths = [pscustomobject][ordered]@{
            active_saved = $Fixture.Paths.active_saved
            inactive_original = $Fixture.Paths.inactive_original
            quarantined_clone = $Fixture.Paths.quarantined_clone
            original_inventory = $Fixture.Paths.original_inventory
            restored_inventory = $Fixture.Paths.restored_inventory
            restore_receipts = $Fixture.Paths.restore_receipts
            probe_restore_final_receipt = (Join-Path $Fixture.Paths.probe_receipts "restore\999-probe-restore-final.json")
        }
        steps = [object[]]$steps.ToArray()
    }
}

function Write-CgceFilesRecoveryOperation($Fixture, $Intent, [int]$Index) {
    $step = @($Intent.steps)[$Index]
    $sequence = [int]$step.sequence
    $previous = if ($Index -eq 0) {
        Get-CgceSha256 (Join-Path $Fixture.Paths.restore_receipts "000-restore-intent.json")
    } else {
        Get-CgceSha256 (Join-Path $Fixture.Paths.restore_receipts "010-quarantine-clone.json")
    }
    $receipt = [pscustomobject][ordered]@{
        schema_version = "1.0"; kind = "cgce_windows_discovery_restore_operation"
        run_id = $Intent.run_id; sequence = $sequence
        step = $step.step; operation = $step.operation
        source_path = $step.source_path; destination_path = $step.destination_path
        before_state = $step.before_state; after_state = $step.after_state
        previous_receipt_sha256 = $previous
        completed_at_utc = "2026-07-24T00:00:0$($Index + 2)Z"
    }
    $leaf = if ($Index -eq 0) {
        "010-quarantine-clone.json"
    } else { "020-restore-original.json" }
    Write-CgceJsonAtomic $receipt (Join-Path $Fixture.Paths.restore_receipts $leaf)
}

function Get-CgceFilesRecoverySnapshot($Fixture) {
    $records = New-Object 'Collections.Generic.List[string]'
    foreach ($item in @(
            Get-ChildItem -LiteralPath $Fixture.Root -Recurse -Force |
                Sort-Object -Property FullName
        )) {
        $relative = $item.FullName.Substring($Fixture.Root.Length)
        if ($relative.StartsWith("\")) {
            $relative = $relative.Substring(1)
        }
        if ($item.PSIsContainer) {
            $null = $records.Add("D|$relative")
        } else {
            $null = $records.Add(
                "F|$relative|$($item.Length)|$(Get-CgceFilesTestSha256 $item.FullName)"
            )
        }
    }
    return [string]::Join("`n", [string[]]$records.ToArray())
}

Invoke-CgceTest "recovery matrix freezes the exact phase case and two-step contract" {
    foreach ($case in @(
            [pscustomobject]@{ Phase = "CREATED"; Case = "UNCHANGED_ORIGINAL" },
            [pscustomobject]@{ Phase = "BACKUP_VERIFIED"; Case = "UNCHANGED_ORIGINAL" },
            [pscustomobject]@{ Phase = "BACKUP_VERIFIED"; Case = "NO_ACTIVE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "ORIGINAL_DEACTIVATED"; Case = "NO_ACTIVE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "ORIGINAL_DEACTIVATED"; Case = "CLONE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "CLONE_ACTIVE"; Case = "CLONE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "PROBE_STAGED"; Case = "CLONE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "RUNNING"; Case = "CLONE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "CAPTURED"; Case = "CLONE_AND_INACTIVE_ORIGINAL" }
        )) {
        $fixture = New-CgceFilesRecoveryFixture $case.Phase $case.Case
        try {
            $matrix = Assert-CgceRecoveryMatrix -State $fixture.State
            Assert-CgceFilesRecoveryMatrix $fixture $matrix $case.Case
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }

    $allowed = @{
        "CREATED|UNCHANGED_ORIGINAL" = $true
        "BACKUP_VERIFIED|UNCHANGED_ORIGINAL" = $true
        "BACKUP_VERIFIED|NO_ACTIVE_AND_INACTIVE_ORIGINAL" = $true
        "ORIGINAL_DEACTIVATED|NO_ACTIVE_AND_INACTIVE_ORIGINAL" = $true
        "ORIGINAL_DEACTIVATED|CLONE_AND_INACTIVE_ORIGINAL" = $true
        "CLONE_ACTIVE|CLONE_AND_INACTIVE_ORIGINAL" = $true
        "PROBE_STAGED|CLONE_AND_INACTIVE_ORIGINAL" = $true
        "RUNNING|CLONE_AND_INACTIVE_ORIGINAL" = $true
        "CAPTURED|CLONE_AND_INACTIVE_ORIGINAL" = $true
    }
    foreach ($phase in @(
            "CREATED", "BACKUP_VERIFIED", "ORIGINAL_DEACTIVATED",
            "CLONE_ACTIVE", "PROBE_STAGED", "RUNNING", "CAPTURED"
        )) {
        foreach ($layout in @(
                "UNCHANGED_ORIGINAL", "NO_ACTIVE_AND_INACTIVE_ORIGINAL",
                "CLONE_AND_INACTIVE_ORIGINAL"
            )) {
            if ($allowed.ContainsKey("$phase|$layout")) { continue }
            $fixture = New-CgceFilesRecoveryFixture $phase $layout
            try {
                Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                    Assert-CgceRecoveryMatrix -State $fixture.State
                }
            } finally {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "recovery matrix resumes only intent-bound before or after states" {
    foreach ($case in @(
            [pscustomobject]@{ Phase = "CREATED"; Selected = "UNCHANGED_ORIGINAL" },
            [pscustomobject]@{ Phase = "BACKUP_VERIFIED"; Selected = "NO_ACTIVE_AND_INACTIVE_ORIGINAL" },
            [pscustomobject]@{ Phase = "CLONE_ACTIVE"; Selected = "CLONE_AND_INACTIVE_ORIGINAL" }
        )) {
        foreach ($position in @(
                "before-010", "after-010", "before-020", "after-020", "completed-020"
            )) {
            $fixture = New-CgceFilesRecoveryFixture $case.Phase $case.Selected
            try {
                $intent = New-CgceFilesRecoveryIntent $fixture
                $intentPath = Join-Path $fixture.Paths.restore_receipts "000-restore-intent.json"
                Write-CgceJsonAtomic $intent $intentPath
                if ($position -cne "before-010" -and
                    $case.Selected -ceq "CLONE_AND_INACTIVE_ORIGINAL") {
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.active_saved $fixture.Paths.quarantined_clone
                }
                if ($position -in @("before-020", "after-020", "completed-020")) {
                    Write-CgceFilesRecoveryOperation $fixture $intent 0
                }
                if ($position -in @("after-020", "completed-020") -and
                    $case.Selected -cne "UNCHANGED_ORIGINAL") {
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.inactive_original $fixture.Paths.active_saved
                }
                if ($position -ceq "completed-020") {
                    Write-CgceFilesRecoveryOperation $fixture $intent 1
                }
                $matrix = Assert-CgceRecoveryMatrix -State $fixture.State -Intent $intent
                Assert-CgceFilesRecoveryMatrix $fixture $matrix $case.Selected
                if ($position -in @("after-020", "completed-020")) {
                    Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                        Assert-CgceRecoveryMatrix -State $fixture.State
                    }
                }
            } catch {
                throw "CGCE-TEST $($case.Selected) resume ${position}: $($_.Exception.Message)"
            } finally {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "recovery matrix rejects invalid resume authority without mutation" {
    foreach ($case in @(
            "020-without-010",
            "wrong-previous-hash",
            "foreign-child",
            "mismatched-intent-path",
            "mismatched-intent-case",
            "mismatched-intent-state",
            "already-active-without-intent",
            "ambiguous-live-state"
        )) {
        $fixture = New-CgceFilesRecoveryFixture `
            "CLONE_ACTIVE" "CLONE_AND_INACTIVE_ORIGINAL"
        try {
            $intent = New-CgceFilesRecoveryIntent $fixture
            $intentPath = Join-Path `
                $fixture.Paths.restore_receipts `
                "000-restore-intent.json"
            if ($case -cne "already-active-without-intent") {
                Write-CgceJsonAtomic $intent $intentPath
            }

            switch ($case) {
                "020-without-010" {
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.active_saved `
                        $fixture.Paths.quarantined_clone
                    Write-CgceFilesRecoveryOperation $fixture $intent 0
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.inactive_original `
                        $fixture.Paths.active_saved
                    Write-CgceFilesRecoveryOperation $fixture $intent 1
                    Remove-Item -LiteralPath (
                        Join-Path `
                            $fixture.Paths.restore_receipts `
                            "010-quarantine-clone.json"
                    )
                }
                "wrong-previous-hash" {
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.active_saved `
                        $fixture.Paths.quarantined_clone
                    Write-CgceFilesRecoveryOperation $fixture $intent 0
                    $receiptPath = Join-Path `
                        $fixture.Paths.restore_receipts `
                        "010-quarantine-clone.json"
                    $receipt = Read-CgceJsonObject $receiptPath
                    $receipt.previous_receipt_sha256 = ("f" * 64)
                    Write-CgceFilesTestUtf8 `
                        $receiptPath `
                        (ConvertTo-CgceFilesTestJson $receipt)
                }
                "foreign-child" {
                    Write-CgceFilesTestUtf8 `
                        (Join-Path `
                            $fixture.Paths.restore_receipts `
                            "011-foreign.json") `
                        "{}"
                }
                "mismatched-intent-path" {
                    $intent.paths.active_saved = Join-Path `
                        $fixture.Paths.server_root `
                        "Pal\ForeignSaved"
                    Write-CgceFilesTestUtf8 `
                        $intentPath `
                        (ConvertTo-CgceFilesTestJson $intent)
                }
                "mismatched-intent-case" {
                    $intent.selected_case = "UNCHANGED_ORIGINAL"
                    Write-CgceFilesTestUtf8 `
                        $intentPath `
                        (ConvertTo-CgceFilesTestJson $intent)
                }
                "mismatched-intent-state" {
                    $intent.steps[0].before_state.source.tree_sha256 = ("f" * 64)
                    Write-CgceFilesTestUtf8 `
                        $intentPath `
                        (ConvertTo-CgceFilesTestJson $intent)
                }
                "already-active-without-intent" {
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.active_saved `
                        $fixture.Paths.quarantined_clone
                    Move-CgceDirectoryNoOverwrite `
                        $fixture.Paths.inactive_original `
                        $fixture.Paths.active_saved
                }
                "ambiguous-live-state" {
                    $null = Copy-CgceTreeVerified `
                        $fixture.Paths.active_saved `
                        $fixture.Paths.quarantined_clone
                }
            }

            $before = Get-CgceFilesRecoverySnapshot $fixture
            Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                if ($case -ceq "already-active-without-intent") {
                    Assert-CgceRecoveryMatrix -State $fixture.State
                } else {
                    Assert-CgceRecoveryMatrix `
                        -State $fixture.State `
                        -Intent $intent
                }
            }
            Assert-CgceEqual `
                $before `
                (Get-CgceFilesRecoverySnapshot $fixture)
        } catch {
            throw "CGCE-TEST resume rejection ${case}: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CgceTest "recovery matrix rejects foreign quarantine without mutation" {
    $fixture = New-CgceFilesRecoveryFixture `
        "CLONE_ACTIVE" "CLONE_AND_INACTIVE_ORIGINAL"
    try {
        New-Item -ItemType Directory -Path $fixture.Paths.quarantined_clone | Out-Null
        Write-CgceFilesTestUtf8 `
            (Join-Path $fixture.Paths.quarantined_clone "foreign.txt") `
            "foreign"
        $cloneBefore = Get-CgceFilesTestSha256 (Join-Path $fixture.Paths.active_saved "World.sav")
        $foreignBefore = Get-CgceFilesTestSha256 (Join-Path $fixture.Paths.quarantined_clone "foreign.txt")
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Assert-CgceRecoveryMatrix -State $fixture.State
        }
        Assert-CgceEqual $cloneBefore (Get-CgceFilesTestSha256 (Join-Path $fixture.Paths.active_saved "World.sav"))
        Assert-CgceEqual $foreignBefore (Get-CgceFilesTestSha256 (Join-Path $fixture.Paths.quarantined_clone "foreign.txt"))
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.Paths.inactive_original -PathType Container)
    } finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}
