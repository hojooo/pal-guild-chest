Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1" -Force
Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Files.psm1" -Force

function New-CgceRuntimeTestRoot {
    $root = Join-Path $env:TEMP ("cgce-runtime-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

function Write-CgceRuntimeTestUtf8([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-CgceRuntimeTestSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-CgceRuntimeExactKeys($Value, [string[]]$Expected) {
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-CgceEqual `
        ([string]::Join(",", $Expected)) `
        ([string]::Join(",", $actual))
}

function Get-CgceRuntimeTestFramedDigest(
    [string]$Domain,
    [string[]]$Values
) {
    $module = Get-Module "CgceDiscovery.Runtime"
    return & $module {
        param($DigestDomain, $DigestValues)
        Get-CgceFramedStringArraySha256 `
            -Domain $DigestDomain `
            -Values $DigestValues
    } $Domain $Values
}

function Set-CgceRuntimeTestCrashSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestProbeCrashSeam = $Value
    } $Seam
}

function Set-CgceRuntimeTestActivitySeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestActivitySnapshotSeam = $Value
    } $Seam
}

function New-CgceRuntimeProbeFixture {
    $base = New-CgceRuntimeTestRoot
    $serverRoot = Join-Path $base "server"
    $saved = Join-Path $serverRoot "Pal\Saved"
    $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
    $mods = Join-Path $ue4ssRoot "Mods"
    $runRoot = Join-Path $base "run"
    $runId = "r-0123456789abcdef0123456789abcdef"
    New-Item -ItemType Directory -Path $saved -Force | Out-Null
    New-Item -ItemType Directory -Path $mods -Force | Out-Null
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $ue4ssRoot "UE4SS.dll") `
        -Value "synthetic" -NoNewline
    Write-CgceRuntimeTestUtf8 `
        -Path (Join-Path $mods "mods.txt") `
        -Text "BPModLoaderMod : 1`r`n; preserved comment`r`n"
    Write-CgceRuntimeTestUtf8 `
        -Path (Join-Path $ue4ssRoot "UE4SS_ObjectDump.txt") `
        -Text "old objects"
    New-Item -ItemType Directory -Path (Join-Path $ue4ssRoot "CXXHeaderDump") |
        Out-Null
    Write-CgceRuntimeTestUtf8 `
        -Path (Join-Path $ue4ssRoot "CXXHeaderDump\Old.hpp") `
        -Text "old headers"
    Write-CgceRuntimeTestUtf8 `
        -Path (Join-Path $ue4ssRoot "UE4SS.log") `
        -Text "old log"

    $paths = New-CgceRunPaths `
        -ServerRoot $serverRoot `
        -SavedPath $saved `
        -Ue4ssRoot $ue4ssRoot `
        -RunRoot $runRoot `
        -RunId $runId
    New-Item -ItemType Directory -Path $paths.run_directory | Out-Null
    New-Item -ItemType Directory -Path $paths.probe_receipts -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $paths.run_directory "before") |
        Out-Null

    return [pscustomobject]@{
        Base = $base
        Ue4ssRoot = $ue4ssRoot
        RunId = $runId
        Paths = $paths
        ProbeSource = (Join-Path $PSScriptRoot `
            "..\..\tools\windows-discovery\probe\CGCEDiscoveryInventory")
        ModsChecksum = (Get-CgceRuntimeTestSha256 $paths.mods_txt)
        ObjectChecksum = (Get-CgceRuntimeTestSha256 $paths.object_dump)
        HeaderInventory = @(Get-CgceTreeInventory -Root $paths.cxx_header_dump)
        LogChecksum = (Get-CgceRuntimeTestSha256 $paths.ue4ss_log)
    }
}

function Assert-CgceRuntimeBeforeImages($Fixture) {
    Assert-CgceEqual $Fixture.ModsChecksum `
        (Get-CgceRuntimeTestSha256 $Fixture.Paths.mods_txt)
    Assert-CgceEqual $Fixture.ObjectChecksum `
        (Get-CgceRuntimeTestSha256 $Fixture.Paths.object_dump)
    Compare-CgceInventory `
        -Expected $Fixture.HeaderInventory `
        -Actual @(Get-CgceTreeInventory -Root $Fixture.Paths.cxx_header_dump)
    Assert-CgceEqual $Fixture.LogChecksum `
        (Get-CgceRuntimeTestSha256 $Fixture.Paths.ue4ss_log)
}

function New-CgceRuntimeActivitySnapshot(
    [object[]]$Processes,
    [object[]]$Tcp,
    [object[]]$Udp,
    [bool]$CimAvailable = $true,
    [bool]$TcpAvailable = $true,
    [bool]$UdpAvailable = $true
) {
    return [pscustomobject]@{
        cim_available = $CimAvailable
        tcp_available = $TcpAvailable
        udp_available = $UdpAvailable
        processes = [object[]]$Processes
        tcp = [object[]]$Tcp
        udp = [object[]]$Udp
    }
}

Invoke-CgceTest "server arguments reject public secret and native parsing hazards" {
    foreach ($argument in @(
        "-publiclobby",
        "-PublicLobby=true",
        "-AdminPassword",
        "-adminpassword=value",
        "-ServerPassword=value",
        "-RCONPassword=value",
        "-RESTAPIKey=value",
        "",
        "has space",
        '"quoted"',
        "semi;colon",
        "pipe|value",
        "redirect>value",
        "@response.txt",
        "line`nbreak"
    )) {
        Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
            Assert-CgceServerArguments -Arguments @($argument)
        }
    }
}

Invoke-CgceTest "server arguments accept only inert non-empty tokens" {
    Assert-CgceServerArguments -Arguments @(
        "-port=8211",
        "-useperfthreads",
        "D:\PalServer\PalServer.exe",
        "/NoAsyncLoadingThread",
        "127.0.0.1:8211"
    )
    Assert-CgceServerArguments -Arguments @("-port=8211")
}

Invoke-CgceTest "framed argument and path digests match fixed vectors" {
    Assert-CgceEqual `
        "6bb80cc11b1721d9e11d93b8ea49097f191ec7323c2663b695746b07cde8648b" `
        (Get-CgceRuntimeTestFramedDigest `
            -Domain "CGCE-ARGS-1" `
            -Values @("-port=8211"))
    Assert-CgceEqual `
        "4ddb0fc59f1926ba915f9af06c7e78a85bbdcedadc1df9159282e57b098cd01c" `
        (Get-CgceRuntimeTestFramedDigest `
            -Domain "CGCE-ARGS-1" `
            -Values @("-port=8211", "-useperfthreads"))
    Assert-CgceEqual `
        "bce0b2e07f77f667c7f9cdc00c5c8987f0b0bb491dfb6c7443b202665f96d410" `
        (Get-CgceRuntimeTestFramedDigest `
            -Domain "CGCE-PATHS-1" `
            -Values @("D:\PalServer\PalServer.exe"))
}

Invoke-CgceTest "server activity requires exhaustive paths and all telemetry" {
    Set-CgceRuntimeTestActivitySeam {
        New-CgceRuntimeActivitySnapshot `
            -Processes @() -Tcp @() -Udp @() -CimAvailable $false
    }
    try {
        Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot `
                -Processes @() -Tcp @() -Udp @() -TcpAvailable $false
        }
        Assert-CgceThrows "CGCE-OPS-PORT-QUERY" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot `
                -Processes @() -Tcp @() -Udp @() -UdpAvailable $false
        }
        Assert-CgceThrows "CGCE-OPS-PORT-QUERY" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Assert-CgceNoServerActivity -ExecutablePaths @() -Ports @(8211)
        }
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @()
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
    }
}

Invoke-CgceTest "server activity blocks exact process images and configured ports" {
    try {
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @(
                [pscustomobject]@{
                    ProcessId = 10
                    ParentProcessId = 1
                    ExecutablePath = "d:\palserver\PALSERVER.EXE"
                    CreationDate = "20260723010101.000000+000"
                }
            ) -Tcp @() -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @(
                [pscustomobject]@{ LocalPort = 8211; State = "Listen" }
            ) -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @(
                [pscustomobject]@{ LocalPort = 8211 }
            )
        }
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211)
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
    }
}

Invoke-CgceTest "receipt-aware activity validates allowlist digest and PID identity" {
    $root = New-CgceRuntimeTestRoot
    try {
        $runId = "r-0123456789abcdef0123456789abcdef"
        $receiptRoot = Join-Path $root "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $allowed = @("D:\PalServer\PalServer.exe")
        $launch = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_launch"
            run_id = $runId
            sequence = 0
            created_at_utc = "2026-07-23T01:00:00Z"
            executable_path = "D:\PalServer\PalServer.exe"
            executable_sha256 = ("a" * 64)
            working_directory = "D:\PalServer"
            allowed_executable_path_count = 1
            allowed_executable_paths_sha256 = (Get-CgceRuntimeTestFramedDigest `
                -Domain "CGCE-PATHS-1" -Values $allowed)
            argument_count = 1
            arguments_sha256 = ("b" * 64)
            timeout_seconds = 30
            previous_receipt_sha256 = $null
        }
        $launchPath = Join-Path $receiptRoot "000-launch.json"
        Write-CgceJsonAtomic -Value $launch -Path $launchPath
        $pidReceipt = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $runId
            sequence = 1
            pid = 42
            parent_pid = 1
            executable_path = "D:\PalServer\PalServer.exe"
            creation_time_utc = "2026-07-23T01:01:01Z"
            creation_time_filetime_utc = [int64]133976484610000000
            observed_at_utc = "2026-07-23T01:01:02Z"
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $launchPath)
        }
        Write-CgceJsonAtomic `
            -Value $pidReceipt `
            -Path (Join-Path $receiptRoot "001-pid.json")
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @(
                [pscustomobject]@{
                    ProcessId = 42
                    ParentProcessId = 1
                    ExecutablePath = "D:\Windows\System32\cmd.exe"
                    CreationDate = "20260723020202.000000+000"
                }
            ) -Tcp @() -Udp @()
        }
        Assert-CgceNoServerActivity `
            -ExecutablePaths $allowed `
            -Ports @(8211) `
            -ReceiptRoot $receiptRoot

        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @(
                    "D:\PalServer\PalServer.exe",
                    "D:\PalServer\Child.exe"
                ) `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "inventory probe writes one exact mods line and sole final receipt" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        $receipt = Enable-CgceInventoryProbe `
            -Ue4ssRoot $fixture.Ue4ssRoot `
            -ProbeSource $fixture.ProbeSource `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.RunId `
            -Paths $fixture.Paths
        Assert-CgceEqual $fixture.Paths.probe_receipt $receipt.path
        Assert-CgceEqual `
            (Get-CgceRuntimeTestSha256 $fixture.Paths.probe_receipt) `
            $receipt.checksum
        $bytes = [System.IO.File]::ReadAllBytes($fixture.Paths.mods_txt)
        Assert-CgceEqual `
            "CGCEDiscoveryInventory : 1`r`n" `
            ([System.Text.Encoding]::UTF8.GetString($bytes))
        Assert-CgceEqual $false `
            ($bytes.Length -ge 3 -and
                $bytes[0] -eq 0xef -and
                $bytes[1] -eq 0xbb -and
                $bytes[2] -eq 0xbf)
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath $fixture.Paths.probe_staged -PathType Container)
        Assert-CgceEqual 1 `
            @(Get-ChildItem -LiteralPath $fixture.Paths.probe_receipts `
                -Filter "999-probe-final.json").Count
        $final = Read-CgceJsonObject -Path $fixture.Paths.probe_receipt
        Assert-CgceRuntimeExactKeys $final @(
            "schema_version",
            "kind",
            "run_id",
            "sequence",
            "intent_sha256",
            "previous_receipt_sha256",
            "mods_before_sha256",
            "mods_after_sha256",
            "staged_path",
            "paths",
            "operation_receipts",
            "completed_at_utc"
        )
        Assert-CgceEqual "cgce_windows_discovery_probe_final" $final.kind
        Assert-CgceEqual 999 $final.sequence
        Assert-CgceEqual 6 @($final.operation_receipts).Count
        Assert-CgceEqual 10 $final.operation_receipts[0].sequence
        Assert-CgceEqual 60 $final.operation_receipts[5].sequence
        foreach ($binding in @($final.operation_receipts)) {
            Assert-CgceRuntimeExactKeys $binding @("sequence", "path", "sha256")
            Assert-CgceEqual `
                $binding.sha256 `
                (Get-CgceRuntimeTestSha256 $binding.path)
            $operationReceipt = Read-CgceJsonObject -Path $binding.path
            Assert-CgceRuntimeExactKeys $operationReceipt @(
                "schema_version",
                "kind",
                "run_id",
                "sequence",
                "step",
                "operation",
                "source_path",
                "destination_path",
                "before_state",
                "after_state",
                "previous_receipt_sha256",
                "completed_at_utc"
            )
            foreach ($pair in @(
                $operationReceipt.before_state,
                $operationReceipt.after_state
            )) {
                Assert-CgceRuntimeExactKeys $pair @("source", "destination")
                foreach ($state in @($pair.source, $pair.destination)) {
                    if ($null -ne $state) {
                        Assert-CgceRuntimeExactKeys $state @(
                            "artifact_type",
                            "present",
                            "length",
                            "sha256",
                            "tree_sha256"
                        )
                    }
                }
            }
        }

        $snapshotNames = @(
            "010-mods-txt.json",
            "020-object-dump.json",
            "030-cxx-header-dump.json",
            "040-ue4ss-log.json",
            "050-probe-source.json"
        )
        foreach ($name in $snapshotNames) {
            $snapshot = Read-CgceJsonObject `
                -Path (Join-Path $fixture.Paths.run_directory "before\$name")
            Assert-CgceRuntimeExactKeys $snapshot @(
                "schema_version",
                "kind",
                "run_id",
                "artifact_name",
                "artifact_type",
                "path",
                "present",
                "length",
                "sha256",
                "entries"
            )
            Assert-CgceEqual `
                "cgce_windows_discovery_artifact_snapshot" `
                $snapshot.kind
        }

        Restore-CgceInventoryProbe `
            -Paths $fixture.Paths `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.RunId `
            -ExpectedFinalReceiptChecksum $receipt.checksum
        Assert-CgceRuntimeBeforeImages $fixture
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath $fixture.Paths.probe_quarantine)
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath $fixture.Paths.probe_staged)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "inventory probe rejects missing prerequisites existing probe and duplicate line" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        [System.IO.File]::Delete($fixture.Paths.ue4ss_dll)
        Assert-CgceThrows "CGCE-OPS-PROBE-EXISTS" {
            Enable-CgceInventoryProbe `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -ProbeSource $fixture.ProbeSource `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -Paths $fixture.Paths
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }

    $fixture = New-CgceRuntimeProbeFixture
    try {
        New-Item -ItemType Directory -Path $fixture.Paths.probe_staged | Out-Null
        Assert-CgceThrows "CGCE-OPS-PROBE-EXISTS" {
            Enable-CgceInventoryProbe `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -ProbeSource $fixture.ProbeSource `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -Paths $fixture.Paths
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }

    $fixture = New-CgceRuntimeProbeFixture
    try {
        Write-CgceRuntimeTestUtf8 `
            -Path $fixture.Paths.mods_txt `
            -Text "CGCEDiscoveryInventory : 1`r`n"
        Assert-CgceThrows "CGCE-OPS-MODS-TXT" {
            Enable-CgceInventoryProbe `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -ProbeSource $fixture.ProbeSource `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -Paths $fixture.Paths
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "probe staging crash points restore exact UE4SS before images" {
    $sequences = @(10, 20, 30, 40, 50, 60, 999)
    foreach ($sequence in $sequences) {
        $padded = $sequence.ToString("000")
        $boundaries = if ($sequence -eq 999) {
            @("before-receipt", "after-receipt")
        } else {
            @(
                "before-operation",
                "after-operation",
                "before-receipt",
                "after-receipt"
            )
        }
        foreach ($boundary in $boundaries) {
            $fixture = New-CgceRuntimeProbeFixture
            try {
                $crashPoint = "$boundary-$padded"
                Set-CgceRuntimeTestCrashSeam {
                    param($Point)
                    if ($Point -ceq $crashPoint) {
                        throw "CGCE-TEST-INJECTED-CRASH $Point"
                    }
                }.GetNewClosure()
                Assert-CgceThrows "CGCE-TEST-INJECTED-CRASH" {
                    Enable-CgceInventoryProbe `
                        -Ue4ssRoot $fixture.Ue4ssRoot `
                        -ProbeSource $fixture.ProbeSource `
                        -RunDirectory $fixture.Paths.run_directory `
                        -RunId $fixture.RunId `
                        -Paths $fixture.Paths
                }
                Set-CgceRuntimeTestCrashSeam $null
                try {
                    Restore-CgceInventoryProbe `
                        -Paths $fixture.Paths `
                        -RunDirectory $fixture.Paths.run_directory `
                        -RunId $fixture.RunId
                    Assert-CgceRuntimeBeforeImages $fixture
                } catch {
                    if ($_.Exception.Message -notlike "CGCE-OPS-MANUAL-RECOVERY*") {
                        throw
                    }
                    Assert-CgceEqual $true `
                        (Test-Path -LiteralPath $fixture.Paths.probe_intent)
                }
            } finally {
                Set-CgceRuntimeTestCrashSeam $null
                Remove-Item -LiteralPath $fixture.Base -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "probe restore blocks ambiguous source and destination without overwrite" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        $receipt = Enable-CgceInventoryProbe `
            -Ue4ssRoot $fixture.Ue4ssRoot `
            -ProbeSource $fixture.ProbeSource `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.RunId `
            -Paths $fixture.Paths
        Write-CgceRuntimeTestUtf8 `
            -Path $fixture.Paths.mods_txt `
            -Text "unrelated bytes"
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Restore-CgceInventoryProbe `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum
        }
        Assert-CgceEqual "unrelated bytes" `
            ([System.IO.File]::ReadAllText($fixture.Paths.mods_txt))
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath $fixture.Paths.mods_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "probe restore resumes every operation and receipt crash boundary" {
    foreach ($sequence in @(10, 20, 30, 40, 50, 60, 70, 80, 90, 999)) {
        $padded = $sequence.ToString("000")
        $boundaries = if ($sequence -eq 999) {
            @("restore-before-receipt", "restore-after-receipt")
        } else {
            @(
                "restore-before-operation",
                "restore-after-operation",
                "restore-before-receipt",
                "restore-after-receipt"
            )
        }
        foreach ($boundary in $boundaries) {
            $fixture = New-CgceRuntimeProbeFixture
            try {
                $receipt = Enable-CgceInventoryProbe `
                    -Ue4ssRoot $fixture.Ue4ssRoot `
                    -ProbeSource $fixture.ProbeSource `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -Paths $fixture.Paths
                $crashPoint = "$boundary-$padded"
                Set-CgceRuntimeTestCrashSeam {
                    param($Point)
                    if ($Point -ceq $crashPoint) {
                        throw "CGCE-TEST-INJECTED-CRASH $Point"
                    }
                }.GetNewClosure()
                Assert-CgceThrows "CGCE-TEST-INJECTED-CRASH" {
                    Restore-CgceInventoryProbe `
                        -Paths $fixture.Paths `
                        -RunDirectory $fixture.Paths.run_directory `
                        -RunId $fixture.RunId `
                        -ExpectedFinalReceiptChecksum $receipt.checksum
                }
                Set-CgceRuntimeTestCrashSeam $null
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -ExpectedFinalReceiptChecksum $receipt.checksum
                Assert-CgceRuntimeBeforeImages $fixture
                Assert-CgceEqual $true (Test-Path -LiteralPath (
                    Join-Path $fixture.Paths.probe_receipts `
                        "restore\999-probe-restore-final.json"
                ))
            } finally {
                Set-CgceRuntimeTestCrashSeam $null
                Remove-Item -LiteralPath $fixture.Base -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "probe restore rejects tampered frozen plans operations paths and states" {
    foreach ($tamper in @("plan", "operation", "path", "state")) {
        $fixture = New-CgceRuntimeProbeFixture
        try {
            $receipt = Enable-CgceInventoryProbe `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -ProbeSource $fixture.ProbeSource `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -Paths $fixture.Paths
            $crashPoint = if ($tamper -ceq "plan") {
                "restore-before-operation-010"
            } else {
                "restore-after-receipt-010"
            }
            Set-CgceRuntimeTestCrashSeam {
                param($Point)
                if ($Point -ceq $crashPoint) {
                    throw "CGCE-TEST-INJECTED-CRASH $Point"
                }
            }.GetNewClosure()
            Assert-CgceThrows "CGCE-TEST-INJECTED-CRASH" {
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -ExpectedFinalReceiptChecksum $receipt.checksum
            }
            Set-CgceRuntimeTestCrashSeam $null
            $restoreRoot = Join-Path $fixture.Paths.probe_receipts "restore"
            if ($tamper -ceq "plan") {
                $path = Join-Path $restoreRoot "000-probe-restore-intent.json"
                $value = Read-CgceJsonObject $path
                $value.plans[0].selected_case = "ORIGINAL_UNCHANGED"
            } else {
                $path = Join-Path $restoreRoot "010-quarantine-probe.json"
                $value = Read-CgceJsonObject $path
                if ($tamper -ceq "operation") {
                    $value.operation = "MOVE_FILE"
                } elseif ($tamper -ceq "path") {
                    $value.source_path = $fixture.Paths.mods_txt
                } else {
                    $value.before_state.source.sha256 = ("f" * 64)
                }
            }
            Write-CgceRuntimeTestUtf8 `
                -Path $path `
                -Text ($value | ConvertTo-Json -Depth 12)
            Assert-CgceThrows "CGCE-OPS-PROBE-RECEIPT" {
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -ExpectedFinalReceiptChecksum $receipt.checksum
            }
        } finally {
            Set-CgceRuntimeTestCrashSeam $null
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "foreign artifact preflight blocks active originals probe and mods enablement" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        $activeMarker = Join-Path `
            $fixture.Paths.server_root `
            ".cgce-discovery-active.json"
        Write-CgceRuntimeTestUtf8 -Path $activeMarker -Text "{}"
        Assert-CgceThrows "CGCE-OPS-FOREIGN-ARTIFACT" {
            Assert-CgceNoForeignRunArtifacts `
                -ServerRoot $fixture.Paths.server_root `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -RunId $fixture.RunId
        }
        [System.IO.File]::Delete($activeMarker)

        $foreignOriginal = $fixture.Paths.active_saved +
            ".cgce-original-r-ffffffffffffffffffffffffffffffff"
        [System.IO.Directory]::CreateDirectory($foreignOriginal) | Out-Null
        Assert-CgceThrows "CGCE-OPS-FOREIGN-ARTIFACT" {
            Assert-CgceNoForeignRunArtifacts `
                -ServerRoot $fixture.Paths.server_root `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -RunId $fixture.RunId
        }
        [System.IO.Directory]::Delete($foreignOriginal)

        [System.IO.Directory]::CreateDirectory($fixture.Paths.probe_staged) |
            Out-Null
        Assert-CgceThrows "CGCE-OPS-PROBE-EXISTS" {
            Assert-CgceNoForeignRunArtifacts `
                -ServerRoot $fixture.Paths.server_root `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -RunId $fixture.RunId
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "child process writes immutable intent PID and result receipts without arguments" {
    $base = New-CgceRuntimeTestRoot
    try {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "CGCE-TEST ComSpec is required on Windows"
        }
        $runId = "r-0123456789abcdef0123456789abcdef"
        $receiptRoot = Join-Path $base "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $executable = [System.IO.Path]::GetFullPath($env:ComSpec)
        $checksum = Get-CgceRuntimeTestSha256 $executable
        $run = Invoke-CgceChildProcess `
            -Executable $executable `
            -ExpectedExecutableChecksum $checksum `
            -AllowedExecutablePaths @($executable) `
            -Arguments @("/d", "/c", "exit", "/b", "7") `
            -ReceiptRoot $receiptRoot `
            -TimeoutSeconds 30

        Assert-CgceEqual 7 $run.result.exit_code
        Assert-CgceEqual `
            (Get-CgceRuntimeTestSha256 (Join-Path $receiptRoot "000-launch.json")) `
            $run.launch_receipt_checksum
        Assert-CgceEqual `
            (Get-CgceRuntimeTestSha256 (Join-Path $receiptRoot "999-result.json")) `
            $run.result_receipt_checksum

        $launch = Read-CgceJsonObject `
            -Path (Join-Path $receiptRoot "000-launch.json")
        Assert-CgceRuntimeExactKeys $launch @(
            "schema_version",
            "kind",
            "run_id",
            "sequence",
            "created_at_utc",
            "executable_path",
            "executable_sha256",
            "working_directory",
            "allowed_executable_path_count",
            "allowed_executable_paths_sha256",
            "argument_count",
            "arguments_sha256",
            "timeout_seconds",
            "previous_receipt_sha256"
        )
        Assert-CgceEqual "cgce_windows_discovery_process_launch" $launch.kind
        Assert-CgceEqual 0 $launch.sequence
        Assert-CgceEqual 5 $launch.argument_count
        Assert-CgceEqual $null $launch.previous_receipt_sha256

        $pidReceipt = Read-CgceJsonObject `
            -Path (Join-Path $receiptRoot "001-pid.json")
        Assert-CgceRuntimeExactKeys $pidReceipt @(
            "schema_version",
            "kind",
            "run_id",
            "sequence",
            "pid",
            "parent_pid",
            "executable_path",
            "creation_time_utc",
            "creation_time_filetime_utc",
            "observed_at_utc",
            "previous_receipt_sha256"
        )
        Assert-CgceEqual "cgce_windows_discovery_process_pid" $pidReceipt.kind
        Assert-CgceEqual 1 $pidReceipt.sequence
        Assert-CgceEqual $run.launch_receipt_checksum `
            $pidReceipt.previous_receipt_sha256

        Assert-CgceRuntimeExactKeys $run.result @(
            "schema_version",
            "kind",
            "run_id",
            "sequence",
            "launch_receipt_sha256",
            "previous_receipt_sha256",
            "started_at_utc",
            "exit_at_utc",
            "exit_code",
            "observed_processes",
            "pid_receipts"
        )
        Assert-CgceEqual "cgce_windows_discovery_process_result" $run.result.kind
        Assert-CgceEqual 999 $run.result.sequence
        Assert-CgceEqual 1 @($run.result.observed_processes).Count
        Assert-CgceEqual 1 @($run.result.pid_receipts).Count

        $allReceiptText = [string]::Join(
            "`n",
            @(Get-ChildItem -LiteralPath $receiptRoot -File |
                ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
        )
        Assert-CgceEqual $false $allReceiptText.Contains("/d")
        Assert-CgceEqual $false $allReceiptText.Contains("exit")

        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30
        }
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "runtime module exports only its approved Task 3 surface" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $actual = @($module.ExportedFunctions.Keys | Sort-Object)
    $expected = @(
        "Assert-CgceNoForeignRunArtifacts",
        "Assert-CgceNoServerActivity",
        "Assert-CgceServerArguments",
        "Enable-CgceInventoryProbe",
        "Invoke-CgceChildProcess",
        "Restore-CgceInventoryProbe"
    ) | Sort-Object
    Assert-CgceEqual `
        ([string]::Join(",", $expected)) `
        ([string]::Join(",", $actual))
}
