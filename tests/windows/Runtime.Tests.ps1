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

function Set-CgceRuntimeTestRootProcessRecordSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestRootProcessRecordSeam = $Value
    } $Seam
}

function Set-CgceRuntimeTestProcessRecordsSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestProcessRecordsSeam = $Value
    } $Seam
}

function Set-CgceRuntimeTestLaunchReceiptSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestLaunchReceiptSeam = $Value
    } $Seam
}

function Set-CgceRuntimeTestProcessCrashSeam($Seam) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $script:CgceTestProcessCrashSeam = $Value
    } $Seam
}

function Wait-CgceRuntimeTestReceiptRootExit([string]$ReceiptRoot) {
    $rootReceipt = Read-CgceJsonObject `
        -Path (Join-Path $ReceiptRoot "001-pid.json")
    $rootProcess = Get-Process `
        -Id ([int]$rootReceipt.pid) `
        -ErrorAction SilentlyContinue
    if ($null -eq $rootProcess) { return }
    $sameRoot = $false
    try {
        $sameRoot = (
            $rootProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        ) -eq [int64]$rootReceipt.creation_time_filetime_utc
    } catch {
        $sameRoot = $false
    }
    try {
        if ($sameRoot -and -not $rootProcess.WaitForExit(5000)) {
            throw "CGCE-TEST root process did not exit"
        }
    } finally {
        $rootProcess.Dispose()
    }
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

function Initialize-CgceRuntimePreparedProbeFixture($Fixture) {
    foreach ($directory in @(
        (Split-Path -Parent $Fixture.Paths.original_inventory),
        (Split-Path -Parent $Fixture.Paths.backup_saved),
        $Fixture.Paths.capture,
        $Fixture.Paths.process_receipts,
        $Fixture.Paths.restore_receipts
    )) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    Write-CgceRuntimeTestUtf8 `
        -Path (Join-Path $Fixture.Paths.active_saved "World.sav") `
        -Text "synthetic world"
    $original = @(Get-CgceTreeInventory -Root $Fixture.Paths.active_saved)
    $null = Copy-CgceTreeVerified `
        -Source $Fixture.Paths.active_saved `
        -Destination $Fixture.Paths.inactive_original
    $null = Copy-CgceTreeVerified `
        -Source $Fixture.Paths.active_saved `
        -Destination $Fixture.Paths.backup_saved
    $null = Write-CgceInventory `
        -Entries $original `
        -Path $Fixture.Paths.original_inventory `
        -Kind "original"
    $null = Write-CgceInventory `
        -Entries $original `
        -Path $Fixture.Paths.backup_inventory `
        -Kind "backup"
    $null = Write-CgceInventory `
        -Entries $original `
        -Path $Fixture.Paths.clone_inventory `
        -Kind "clone"
    return Enable-CgceInventoryProbe `
        -Ue4ssRoot $Fixture.Ue4ssRoot `
        -ProbeSource $Fixture.ProbeSource `
        -RunDirectory $Fixture.Paths.run_directory `
        -RunId $Fixture.RunId `
        -Paths $Fixture.Paths
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
        "line`nbreak",
        "-port=8211`n",
        "-port=8211`r`n",
        ("x" * 4097)
    )) {
        Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
            Assert-CgceServerArguments -Arguments @($argument)
        }
    }
}

Invoke-CgceTest "Windows native argument quoting preserves exact CRT token boundaries" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $quote = [char]34
    $slash = [char]92
    $vectors = @(
        [pscustomobject]@{
            Value = ""
            Expected = [string]$quote + [string]$quote
        },
        [pscustomobject]@{
            Value = "has space"
            Expected = [string]$quote + "has space" + [string]$quote
        },
        [pscustomobject]@{
            Value = 'embedded"quote'
            Expected = [string]$quote + "embedded" + [string]$slash +
                [string]$quote + "quote" + [string]$quote
        },
        [pscustomobject]@{
            Value = "trailing$slash"
            Expected = [string]$quote + "trailing" +
                ([string]$slash * 2) + [string]$quote
        },
        [pscustomobject]@{
            Value = "&|<>^"
            Expected = [string]$quote + "&|<>^" + [string]$quote
        }
    )
    foreach ($vector in $vectors) {
        $actual = & $module {
            param($Value)
            ConvertTo-CgceWindowsCommandLineArgument -Argument $Value
        } $vector.Value
        Assert-CgceEqual $vector.Expected $actual
    }
    $joined = & $module {
        param($Values)
        ConvertTo-CgceWindowsCommandLine -Arguments $Values
    } ([string[]]@($vectors | ForEach-Object { $_.Value }))
    Assert-CgceEqual `
        ([string]::Join(
            " ",
            [string[]]@($vectors | ForEach-Object { $_.Expected })
        )) `
        $joined
}

Invoke-CgceTest "runtime checksum rejects valid prefixes followed by line endings" {
    $module = Get-Module "CgceDiscovery.Runtime"
    foreach ($suffix in @("`n", "`r`n")) {
        Assert-CgceEqual `
            $false `
            (& $module {
                param($Value)
                Test-CgceRuntimeChecksum $Value
            } (("a" * 64) + $suffix))
    }
}

Invoke-CgceTest "launch receipt requires its bounded timeout inside control validity" {
    $root = New-CgceRuntimeTestRoot
    try {
        $runId = "r-0123456789abcdef0123456789abcdef"
        $path = Join-Path $root "000-launch.json"
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
            allowed_executable_paths_sha256 = ("b" * 64)
            argument_count = 0
            arguments_sha256 = ("c" * 64)
            timeout_seconds = 30
            control_valid_until_utc = "2026-07-23T01:00:29Z"
            previous_receipt_sha256 = $null
        }
        Write-CgceJsonAtomic -Value $launch -Path $path
        $module = Get-Module "CgceDiscovery.Runtime"
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            & $module {
                param($ReceiptPath, $ExpectedRunId)
                Read-CgceLaunchReceipt `
                    -Path $ReceiptPath `
                    -RunId $ExpectedRunId
            } $path $runId
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
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

Invoke-CgceTest "strict JSON Decimal integers accept only exact Int64 values" {
    $root = New-CgceRuntimeTestRoot
    $module = Get-Module "CgceDiscovery.Runtime"
    try {
        $path = Join-Path $root "numbers.json"
        Write-CgceRuntimeTestUtf8 `
            -Path $path `
            -Text '{"valid":42,"fraction":1.5,"overflow":9223372036854775808,"string":"42","boolean":true}'
        $parsed = Read-CgceJsonObject $path
        Assert-CgceEqual $true (& $module {
            param($Value)
            Test-CgceRuntimeInteger $Value 1 100
        } $parsed.valid)
        foreach ($invalid in @(
            $parsed.fraction,
            $parsed.overflow,
            $parsed.string,
            $parsed.boolean
        )) {
            Assert-CgceEqual $false (& $module {
                param($Value)
                Test-CgceRuntimeInteger $Value 1 ([int64]::MaxValue)
            } $invalid)
        }
        Assert-CgceEqual $true (& $module {
            Test-CgceRuntimeInteger ([int64]42) 1 100
        })
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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
        Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
            Assert-CgceNoServerActivity -ExecutablePaths @() -Ports @(8211)
        }
        Assert-CgceThrows "CGCE-OPS-PORT-QUERY" {
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

Invoke-CgceTest "receipt-aware activity permits an exactly empty first-launch journal" {
    $root = New-CgceRuntimeTestRoot
    try {
        $runId = "r-0123456789abcdef0123456789abcdef"
        $receiptRoot = Join-Path $root "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceNoServerActivity `
            -ExecutablePaths @("D:\PalServer\PalServer.exe") `
            -Ports @(8211) `
            -ReceiptRoot $receiptRoot

        New-Item -ItemType Directory -Path (Join-Path $receiptRoot "foreign") |
            Out-Null
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @("D:\PalServer\PalServer.exe") `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
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
            timeout_seconds = 300
            control_valid_until_utc = "2026-07-23T02:00:00Z"
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
            parent_pid = 0
            executable_path = "D:\PalServer\PalServer.exe"
            creation_time_utc = "2026-07-23T01:01:01Z"
            creation_time_filetime_utc = [int64]134292420610000000
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

Invoke-CgceTest "completed process result binds the exact immutable PID journal" {
    $root = New-CgceRuntimeTestRoot
    try {
        $runId = "r-0123456789abcdef0123456789abcdef"
        $receiptRoot = Join-Path $root "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $allowed = @(
            "D:\PalServer\PalServer.exe",
            "D:\PalServer\PalServer-Win64-Shipping.exe"
        )
        $launch = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_launch"
            run_id = $runId
            sequence = 0
            created_at_utc = "2026-07-23T01:00:00Z"
            executable_path = $allowed[0]
            executable_sha256 = ("a" * 64)
            working_directory = "D:\PalServer"
            allowed_executable_path_count = 2
            allowed_executable_paths_sha256 = (Get-CgceRuntimeTestFramedDigest `
                -Domain "CGCE-PATHS-1" -Values $allowed)
            argument_count = 1
            arguments_sha256 = ("b" * 64)
            timeout_seconds = 300
            control_valid_until_utc = "2026-07-23T02:00:00Z"
            previous_receipt_sha256 = $null
        }
        $launchPath = Join-Path $receiptRoot "000-launch.json"
        Write-CgceJsonAtomic -Value $launch -Path $launchPath
        $pid = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $runId
            sequence = 1
            pid = 42
            parent_pid = 0
            executable_path = $allowed[0]
            creation_time_utc = "2026-07-23T01:01:01Z"
            creation_time_filetime_utc = [int64]134292420610000000
            observed_at_utc = "2026-07-23T01:01:02Z"
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $launchPath)
        }
        $pidPath = Join-Path $receiptRoot "001-pid.json"
        Write-CgceJsonAtomic -Value $pid -Path $pidPath
        $result = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_result"
            run_id = $runId
            sequence = 999
            launch_receipt_sha256 = (Get-CgceRuntimeTestSha256 $launchPath)
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $pidPath)
            started_at_utc = "2026-07-23T01:01:00Z"
            exit_at_utc = "2026-07-23T01:01:03Z"
            exit_code = 0
            observed_processes = @([pscustomobject][ordered]@{
                sequence = 1
                pid = 42
                parent_pid = 0
                executable_path = $allowed[0]
                creation_time_utc = "2026-07-23T01:01:01Z"
                creation_time_filetime_utc = [int64]134292420610000000
            })
            pid_receipts = @([pscustomobject][ordered]@{
                sequence = 1
                path = $pidPath
                sha256 = (Get-CgceRuntimeTestSha256 $pidPath)
            })
        }
        Write-CgceJsonAtomic `
            -Value $result `
            -Path (Join-Path $receiptRoot "999-result.json")
        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceNoServerActivity `
            -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot

        $resultPath = Join-Path $receiptRoot "999-result.json"
        $result.exit_at_utc = "2026-07-23T01:01:01Z"
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }
        $result.exit_at_utc = "2026-07-23T01:05:01Z"
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }
        $result.exit_at_utc = "2026-07-23T01:01:03Z"
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)

        $tamperedResult = Read-CgceJsonObject $resultPath
        $tamperedResult.exit_code = "0"
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($tamperedResult | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)

        $pid.executable_path = $allowed[1]
        Write-CgceRuntimeTestUtf8 `
            -Path $pidPath `
            -Text ($pid | ConvertTo-Json -Depth 12)
        $wrongRootChecksum = Get-CgceRuntimeTestSha256 $pidPath
        $result.previous_receipt_sha256 = $wrongRootChecksum
        $result.observed_processes[0].executable_path = $allowed[1]
        $result.pid_receipts[0].sha256 = $wrongRootChecksum
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }

        [System.IO.File]::Delete($pidPath)
        $result.previous_receipt_sha256 =
            (Get-CgceRuntimeTestSha256 $launchPath)
        $result.observed_processes = @()
        $result.pid_receipts = @()
        Write-CgceRuntimeTestUtf8 `
            -Path $resultPath `
            -Text ($result | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }

        $result.observed_processes = @([pscustomobject][ordered]@{
            sequence = 1
            pid = 42
            parent_pid = 0
            executable_path = $allowed[0]
            creation_time_utc = "2026-07-23T01:01:01Z"
            creation_time_filetime_utc = [int64]134292420610000000
        })
        $result.pid_receipts = @([pscustomobject][ordered]@{
            sequence = 1
            path = $pidPath
            sha256 = $wrongRootChecksum
        })
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed -Ports @(8211) -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "partial process chain retains unlisted descendants for liveness" {
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
            executable_path = $allowed[0]
            executable_sha256 = ("a" * 64)
            working_directory = "D:\PalServer"
            allowed_executable_path_count = 1
            allowed_executable_paths_sha256 = (Get-CgceRuntimeTestFramedDigest `
                -Domain "CGCE-PATHS-1" -Values $allowed)
            argument_count = 1
            arguments_sha256 = ("b" * 64)
            timeout_seconds = 300
            control_valid_until_utc = "2026-07-23T02:00:00Z"
            previous_receipt_sha256 = $null
        }
        $launchPath = Join-Path $receiptRoot "000-launch.json"
        Write-CgceJsonAtomic -Value $launch -Path $launchPath
        $rootPid = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $runId
            sequence = 1
            pid = 42
            parent_pid = 0
            executable_path = $allowed[0]
            creation_time_utc = "2026-07-23T01:01:01Z"
            creation_time_filetime_utc = [int64]134292420610000000
            observed_at_utc = "2026-07-23T01:01:02Z"
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $launchPath)
        }
        $rootPidPath = Join-Path $receiptRoot "001-pid.json"
        Write-CgceJsonAtomic -Value $rootPid -Path $rootPidPath
        $unlistedPid = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_pid"
            run_id = $runId
            sequence = 2
            pid = 43
            parent_pid = 42
            executable_path = "D:\Unexpected\child.exe"
            creation_time_utc = "2026-07-23T01:01:02Z"
            creation_time_filetime_utc = [int64]134292420620000000
            observed_at_utc = "2026-07-23T01:01:03Z"
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $rootPidPath)
        }
        $unlistedPidPath = Join-Path $receiptRoot "002-pid.json"
        Write-CgceJsonAtomic -Value $unlistedPid -Path $unlistedPidPath

        $module = Get-Module "CgceDiscovery.Runtime"
        $chain = & $module {
            param($Root, $Paths)
            Read-CgceProcessReceiptChain `
                -ReceiptRoot $Root `
                -CanonicalPaths $Paths
        } $receiptRoot $allowed
        Assert-CgceEqual 2 @($chain.pid_receipts).Count
        Assert-CgceEqual $true $chain.has_unlisted_pid_receipt

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @(
                [pscustomobject]@{
                    ProcessId = 43
                    ParentProcessId = 42
                    ExecutablePath = "D:\Unexpected\child.exe"
                    CreationTimeFileTimeUtc = [int64]134292420620000000
                }
            ) -Tcp @() -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceNoServerActivity `
            -ExecutablePaths $allowed `
            -Ports @(8211) `
            -ReceiptRoot $receiptRoot

        $result = [pscustomobject][ordered]@{
            schema_version = "1.0"
            kind = "cgce_windows_discovery_process_result"
            run_id = $runId
            sequence = 999
            launch_receipt_sha256 = (Get-CgceRuntimeTestSha256 $launchPath)
            previous_receipt_sha256 = (Get-CgceRuntimeTestSha256 $unlistedPidPath)
            started_at_utc = "2026-07-23T01:01:00Z"
            exit_at_utc = "2026-07-23T01:01:04Z"
            exit_code = 0
            observed_processes = @(
                [pscustomobject][ordered]@{
                    sequence = 1; pid = 42; parent_pid = 0
                    executable_path = $allowed[0]
                    creation_time_utc = "2026-07-23T01:01:01Z"
                    creation_time_filetime_utc = [int64]134292420610000000
                },
                [pscustomobject][ordered]@{
                    sequence = 2; pid = 43; parent_pid = 42
                    executable_path = "D:\Unexpected\child.exe"
                    creation_time_utc = "2026-07-23T01:01:02Z"
                    creation_time_filetime_utc = [int64]134292420620000000
                }
            )
            pid_receipts = @(
                [pscustomobject][ordered]@{
                    sequence = 1
                    path = $rootPidPath
                    sha256 = (Get-CgceRuntimeTestSha256 $rootPidPath)
                },
                [pscustomobject][ordered]@{
                    sequence = 2
                    path = $unlistedPidPath
                    sha256 = (Get-CgceRuntimeTestSha256 $unlistedPidPath)
                }
            )
        }
        Write-CgceJsonAtomic `
            -Value $result `
            -Path (Join-Path $receiptRoot "999-result.json")
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths $allowed `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "partial process chain binds unique temporal parent ancestry" {
    $root = New-CgceRuntimeTestRoot
    try {
        $runId = "r-0123456789abcdef0123456789abcdef"
        $allowed = @(
            "D:\PalServer\PalServer.exe",
            "D:\PalServer\PalServer-Win64-Shipping.exe"
        )
        foreach ($case in @(
            "ROOT",
            "PARENT",
            "ROOT_PARENT",
            "DUPLICATE_PID",
            "PREDATES_PARENT"
        )) {
            $receiptRoot = Join-Path $root "$case\$runId\receipts\process"
            New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
            $launch = [pscustomobject][ordered]@{
                schema_version = "1.0"
                kind = "cgce_windows_discovery_process_launch"
                run_id = $runId
                sequence = 0
                created_at_utc = "2026-07-23T01:00:00Z"
                executable_path = $allowed[0]
                executable_sha256 = ("a" * 64)
                working_directory = "D:\PalServer"
                allowed_executable_path_count = 2
                allowed_executable_paths_sha256 = (
                    Get-CgceRuntimeTestFramedDigest `
                        -Domain "CGCE-PATHS-1" `
                        -Values $allowed
                )
                argument_count = 1
                arguments_sha256 = ("b" * 64)
                timeout_seconds = 30
                control_valid_until_utc = "2026-07-23T02:00:00Z"
                previous_receipt_sha256 = $null
            }
            $launchPath = Join-Path $receiptRoot "000-launch.json"
            Write-CgceJsonAtomic -Value $launch -Path $launchPath
            $pid1 = [pscustomobject][ordered]@{
                schema_version = "1.0"
                kind = "cgce_windows_discovery_process_pid"
                run_id = $runId
                sequence = 1
                pid = 42
                parent_pid = $(if ($case -ceq "ROOT_PARENT") { 1 } else { 0 })
                executable_path = $(if ($case -ceq "ROOT") {
                    $allowed[1]
                } else { $allowed[0] })
                creation_time_utc = "2026-07-23T01:01:01Z"
                creation_time_filetime_utc = [int64]134292420610000000
                observed_at_utc = "2026-07-23T01:01:02Z"
                previous_receipt_sha256 = (
                    Get-CgceRuntimeTestSha256 $launchPath
                )
            }
            $pid1Path = Join-Path $receiptRoot "001-pid.json"
            Write-CgceJsonAtomic -Value $pid1 -Path $pid1Path
            if ($case -in @("PARENT", "DUPLICATE_PID", "PREDATES_PARENT")) {
                $pid2 = [pscustomobject][ordered]@{
                    schema_version = "1.0"
                    kind = "cgce_windows_discovery_process_pid"
                    run_id = $runId
                    sequence = 2
                    pid = $(if ($case -ceq "DUPLICATE_PID") { 42 } else { 43 })
                    parent_pid = $(if ($case -ceq "PARENT") { 999 } else { 42 })
                    executable_path = $allowed[1]
                    creation_time_utc = $(if ($case -ceq "PREDATES_PARENT") {
                        "2026-07-23T01:01:00Z"
                    } else {
                        "2026-07-23T01:01:02Z"
                    })
                    creation_time_filetime_utc = $(if (
                        $case -ceq "PREDATES_PARENT"
                    ) {
                        [int64]134292420600000000
                    } else {
                        [int64]134292420620000000
                    })
                    observed_at_utc = "2026-07-23T01:01:03Z"
                    previous_receipt_sha256 = (
                        Get-CgceRuntimeTestSha256 $pid1Path
                    )
                }
                Write-CgceJsonAtomic `
                    -Value $pid2 `
                    -Path (Join-Path $receiptRoot "002-pid.json")
            }
            $module = Get-Module "CgceDiscovery.Runtime"
            Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
                & $module {
                    param($Root, $Paths)
                    Read-CgceProcessReceiptChain `
                        -ReceiptRoot $Root `
                        -CanonicalPaths $Paths
                } $receiptRoot $allowed
            }
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Invoke-CgceTest "unreadable descendant identity fails closed for manual recovery" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $record = [pscustomobject]@{
        ProcessId = 43
        ParentProcessId = 42
        ExecutablePath = $null
        CreationTimeFileTimeUtc = [int64]134292420620000000
    }
    Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
        & $module {
            param($Value)
            Get-CgceProcessIdentityFromRecord $Value ""
        } $record
    }
}

Invoke-CgceTest "artifact states reject coercion and inventory path aliases" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $valid = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true; length = [decimal]3
        sha256 = ("a" * 64); tree_sha256 = $null
    }
    & $module {
        param($State)
        Assert-CgceArtifactStateSchema `
            $State "FILE" "CGCE-OPS-PROBE-RECEIPT"
    } $valid
    foreach ($invalid in @(
        [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = 1; length = [decimal]3
            sha256 = ("a" * 64); tree_sha256 = $null
        },
        [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true; length = "3"
            sha256 = ("a" * 64); tree_sha256 = $null
        },
        [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true; length = [decimal]3.5
            sha256 = ("a" * 64); tree_sha256 = $null
        },
        [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true; length = [decimal]3
            sha256 = ("A" * 64); tree_sha256 = $null
        }
    )) {
        Assert-CgceThrows "CGCE-OPS-PROBE-RECEIPT" {
            & $module {
                param($State)
                Assert-CgceArtifactStateSchema `
                    $State "FILE" "CGCE-OPS-PROBE-RECEIPT"
            } $invalid
        }
    }
    $coerced = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true; length = "3"
        sha256 = ("a" * 64); tree_sha256 = $null
    }
    Assert-CgceEqual $false (& $module {
        param($Left, $Right)
        Test-CgceArtifactStateEqual $Left $Right
    } $valid $coerced)
    $caseChanged = [pscustomobject][ordered]@{
        artifact_type = "FILE"; present = $true; length = [decimal]3
        sha256 = ("A" * 64); tree_sha256 = $null
    }
    Assert-CgceEqual $false (& $module {
        param($Left, $Right)
        Test-CgceArtifactStateEqual $Left $Right
    } $valid $caseChanged)

    foreach ($relativePath in @(
        ".", "..", "a//b", "a/./b", "a/../b", "a:b", "a\b", "a`0b"
    )) {
        $entry = [pscustomobject][ordered]@{
            relative_path = $relativePath
            length = [decimal]1
            sha256 = ("b" * 64)
        }
        Assert-CgceThrows "CGCE-OPS-INVENTORY" {
            & $module {
                param($Value)
                Compare-CgceInventory -Expected @($Value) -Actual @($Value)
            } $entry
        }
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

Invoke-CgceTest "staged probe authority is output-free and binds inventories journal and live matrix" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        $receipt = Initialize-CgceRuntimePreparedProbeFixture $fixture
        $output = @(
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum
        )
        Assert-CgceEqual 0 $output.Count

        $launchPath = Join-Path `
            $fixture.Paths.process_receipts `
            "000-launch.json"
        Write-CgceJsonAtomic `
            -Value ([pscustomobject][ordered]@{ staged_test = $true }) `
            -Path $launchPath
        $launchChecksum = Get-CgceRuntimeTestSha256 $launchPath
        $launchBoundOutput = @(
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum `
                -ExpectedLaunchReceiptChecksum $launchChecksum
        )
        Assert-CgceEqual 0 $launchBoundOutput.Count
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum `
                -ExpectedLaunchReceiptChecksum ("f" * 64)
        }
        Write-CgceRuntimeTestUtf8 `
            -Path (Join-Path $fixture.Paths.process_receipts "001-pid.json") `
            -Text "{}"
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum `
                -ExpectedLaunchReceiptChecksum $launchChecksum
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "staged probe authority rejects inventory live output and residue drift" {
    $cases = @(
        [pscustomobject]@{
            Name = "clone live drift"
            Code = "CGCE-OPS-INVENTORY"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $Fixture.Paths.active_saved "drift.sav") `
                    -Text "drift"
            }
        },
        [pscustomobject]@{
            Name = "isolated mods drift"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path $Fixture.Paths.mods_txt `
                    -Text "CGCEDiscoveryInventory : 0`r`n"
            }
        },
        [pscustomobject]@{
            Name = "staged probe drift"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $Fixture.Paths.probe_staged "drift.lua") `
                    -Text "return false"
            }
        },
        [pscustomobject]@{
            Name = "generated output appeared"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path $Fixture.Paths.object_dump `
                    -Text "early output"
            }
        },
        [pscustomobject]@{
            Name = "capture residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $Fixture.Paths.capture "foreign.txt") `
                    -Text "foreign"
            }
        },
        [pscustomobject]@{
            Name = "process receipt residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $Fixture.Paths.process_receipts "foreign.json") `
                    -Text "{}"
            }
        },
        [pscustomobject]@{
            Name = "restore journal residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $Fixture.Paths.restore_receipts "foreign.json") `
                    -Text "{}"
            }
        },
        [pscustomobject]@{
            Name = "probe restore journal residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                $restore = Join-Path $Fixture.Paths.probe_receipts "restore"
                New-Item -ItemType Directory -Path $restore -Force | Out-Null
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $restore "foreign.json") `
                    -Text "{}"
            }
        },
        [pscustomobject]@{
            Name = "quarantine residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Mutate = {
                param($Fixture)
                New-Item `
                    -ItemType Directory `
                    -Path $Fixture.Paths.probe_quarantine `
                    -Force | Out-Null
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceRuntimeProbeFixture
        try {
            $receipt = Initialize-CgceRuntimePreparedProbeFixture $fixture
            $null = & $case.Mutate $fixture
            Assert-CgceThrows $case.Code {
                Assert-CgceInventoryProbeStaged `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -ExpectedFinalReceiptChecksum $receipt.checksum
            }
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }

    $fixture = New-CgceRuntimeProbeFixture
    try {
        $receipt = Initialize-CgceRuntimePreparedProbeFixture $fixture
        Assert-CgceThrows "CGCE-OPS-PROBE-RECEIPT" {
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum ("f" * 64)
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "staged probe authority rejects reparse points before reading authority" {
    $fixture = New-CgceRuntimeProbeFixture
    $junction = $null
    try {
        $receipt = Initialize-CgceRuntimePreparedProbeFixture $fixture
        $target = Join-Path $fixture.Base "outside-authority"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $junction = Join-Path $fixture.Paths.run_directory "before\authority-link"
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        Assert-CgceThrows "CGCE-OPS-REPARSE" {
            Assert-CgceInventoryProbeStaged `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum
        }
    } finally {
        if ($null -ne $junction -and (Test-Path -LiteralPath $junction)) {
            [System.IO.Directory]::Delete($junction)
        }
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
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId
                Assert-CgceRuntimeBeforeImages $fixture
            } finally {
                Set-CgceRuntimeTestCrashSeam $null
                Remove-Item -LiteralPath $fixture.Base -Recurse -Force
            }
        }
    }
}

Invoke-CgceTest "probe restore rejects missing intent whenever run residue remains" {
    foreach ($residue in @("original", "journal", "probe", "enablement")) {
        $fixture = New-CgceRuntimeProbeFixture
        try {
            if ($residue -ceq "original") {
                Write-CgceRuntimeTestUtf8 `
                    -Path $fixture.Paths.mods_original `
                    -Text "residual original"
            } elseif ($residue -ceq "journal") {
                Write-CgceRuntimeTestUtf8 `
                    -Path (Join-Path $fixture.Paths.probe_receipts `
                        "010-preserve-mods.json") `
                    -Text "{}"
            } elseif ($residue -ceq "probe") {
                New-Item -ItemType Directory `
                    -Path $fixture.Paths.probe_staged | Out-Null
            } else {
                Write-CgceRuntimeTestUtf8 `
                    -Path $fixture.Paths.mods_txt `
                    -Text "CGCEDiscoveryInventory : 1`r`n"
            }
            Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId
            }
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
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

Invoke-CgceTest "completed restore revalidates final bindings and live terminal matrix" {
    foreach ($tamper in @("final-binding", "restored-state", "live-probe")) {
        $fixture = New-CgceRuntimeProbeFixture
        try {
            $receipt = Enable-CgceInventoryProbe `
                -Ue4ssRoot $fixture.Ue4ssRoot `
                -ProbeSource $fixture.ProbeSource `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -Paths $fixture.Paths
            Restore-CgceInventoryProbe `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId `
                -ExpectedFinalReceiptChecksum $receipt.checksum
            $restoreFinalPath = Join-Path $fixture.Paths.probe_receipts `
                "restore\999-probe-restore-final.json"
            if ($tamper -ceq "live-probe") {
                Move-Item -LiteralPath $fixture.Paths.probe_quarantine `
                    -Destination $fixture.Paths.probe_staged
            } else {
                $final = Read-CgceJsonObject $restoreFinalPath
                if ($tamper -ceq "final-binding") {
                    $final.operation_receipts[0].sha256 = ("f" * 64)
                } else {
                    $final.restored_states[1].state.sha256 = ("f" * 64)
                }
                Write-CgceRuntimeTestUtf8 `
                    -Path $restoreFinalPath `
                    -Text ($final | ConvertTo-Json -Depth 12)
            }
            Assert-CgceThrows "CGCE-OPS-" {
                Restore-CgceInventoryProbe `
                    -Paths $fixture.Paths `
                    -RunDirectory $fixture.Paths.run_directory `
                    -RunId $fixture.RunId `
                    -ExpectedFinalReceiptChecksum $receipt.checksum
            }
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "stage authority rejects semantically re-signed operation receipts" {
    $fixture = New-CgceRuntimeProbeFixture
    try {
        $null = Enable-CgceInventoryProbe `
            -Ue4ssRoot $fixture.Ue4ssRoot `
            -ProbeSource $fixture.ProbeSource `
            -RunDirectory $fixture.Paths.run_directory `
            -RunId $fixture.RunId `
            -Paths $fixture.Paths
        $operationPath = Join-Path $fixture.Paths.probe_receipts `
            "060-stage-probe.json"
        $operation = Read-CgceJsonObject $operationPath
        $operation.operation = "COPY_FILE"
        Write-CgceRuntimeTestUtf8 `
            -Path $operationPath `
            -Text ($operation | ConvertTo-Json -Depth 12)
        $final = Read-CgceJsonObject $fixture.Paths.probe_receipt
        $newChecksum = Get-CgceRuntimeTestSha256 $operationPath
        $final.previous_receipt_sha256 = $newChecksum
        $final.operation_receipts[5].sha256 = $newChecksum
        Write-CgceRuntimeTestUtf8 `
            -Path $fixture.Paths.probe_receipt `
            -Text ($final | ConvertTo-Json -Depth 12)
        Assert-CgceThrows "CGCE-OPS-PROBE-RECEIPT" {
            Restore-CgceInventoryProbe `
                -Paths $fixture.Paths `
                -RunDirectory $fixture.Paths.run_directory `
                -RunId $fixture.RunId
        }
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore case authority distinguishes untouched from journal-restored states" {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        $before = [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true; length = 3
            sha256 = ("a" * 64); tree_sha256 = $null
        }
        $absent = New-CgceAbsentArtifactState "FILE"
        $test = [pscustomobject][ordered]@{
            artifact_type = "FILE"; present = $true; length = 4
            sha256 = ("b" * 64); tree_sha256 = $null
        }
        Assert-CgceEqual "ORIGINAL_UNCHANGED" (
            Get-CgceRestoreSelectedCase `
                "MODS_TXT" $true $before $absent $absent $before $test $false
        )
        Assert-CgceEqual "ORIGINAL_ALREADY_RESTORED" (
            Get-CgceRestoreSelectedCase `
                "MODS_TXT" $true $before $absent $test $before $test $true
        )
        Assert-CgceEqual "ORIGINAL_ALREADY_RESTORED" (
            Get-CgceRestoreSelectedCase `
                "MODS_TXT" $true $before $absent $absent $before $test $true
        )
        Assert-CgceEqual "BEFORE_PRESENT_ALREADY_RESTORED" (
            Get-CgceRestoreSelectedCase `
                "OBJECT_DUMP" $true $before $absent $absent $before $test $false
        )
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Get-CgceRestoreSelectedCase `
                "OBJECT_DUMP" $true $before $absent $test $before $test $false
        }
        Assert-CgceEqual "BEFORE_PRESENT_ALREADY_RESTORED" (
            Get-CgceRestoreSelectedCase `
                "OBJECT_DUMP" $true $before $absent $test $before $test $true
        )
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

Invoke-CgceTest "child process contract bounds inputs and control validity before launch" {
    $command = Get-Command "Invoke-CgceChildProcess"
    foreach ($parameterName in @("ControlValidUntilUtc", "PreLaunchValidation")) {
        $mandatory = @(
            $command.Parameters[$parameterName].Attributes |
                Where-Object {
                    $_ -is [System.Management.Automation.ParameterAttribute]
                } |
                ForEach-Object { $_.Mandatory }
        )
        Assert-CgceEqual $true ($mandatory -contains $true)
    }

    $common = @{
        Executable = "D:\PalServer\PalServer.exe"
        ExpectedExecutableChecksum = ("a" * 64)
        AllowedExecutablePaths = @("D:\PalServer\PalServer.exe")
        Arguments = @("-port=8211")
        ReceiptRoot = "D:\runs\r-0123456789abcdef0123456789abcdef\receipts\process"
        PreLaunchValidation = {}
        ControlValidUntilUtc = [DateTime]::UtcNow.AddMinutes(5).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    foreach ($timeout in @(0, 86401)) {
        Assert-CgceThrows "CGCE-OPS-PROCESS-TIMEOUT" {
            Invoke-CgceChildProcess @common -TimeoutSeconds $timeout
        }
    }

    $manyArguments = @(
        for ($index = 0; $index -lt 4097; $index += 1) {
            "-x$index"
        }
    )
    $tooManyArguments = @{} + $common
    $tooManyArguments.Arguments = [string[]]$manyArguments
    Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
        Invoke-CgceChildProcess @tooManyArguments -TimeoutSeconds 1
    }
    $oversizedCommandLine = @{} + $common
    $oversizedCommandLine.Arguments = [string[]]@(
        for ($index = 0; $index -lt 8; $index += 1) {
            "x" * 4096
        }
    )
    Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
        Invoke-CgceChildProcess @oversizedCommandLine -TimeoutSeconds 1
    }

    $manyPaths = @(
        for ($index = 0; $index -lt 4097; $index += 1) {
            "D:\PalServer\server-$index.exe"
        }
    )
    $tooManyPaths = @{} + $common
    $tooManyPaths.AllowedExecutablePaths = [string[]]$manyPaths
    Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
        Invoke-CgceChildProcess @tooManyPaths -TimeoutSeconds 1
    }
    $oversizedPath = @{} + $common
    $oversizedPath.AllowedExecutablePaths = @(
        "D:\" + ("a" * 4097)
    )
    Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
        Invoke-CgceChildProcess @oversizedPath -TimeoutSeconds 1
    }

    foreach ($validUntil in @(
        "not-a-time",
        [DateTime]::SpecifyKind(
            [DateTime]::UtcNow.AddMinutes(5),
            [DateTimeKind]::Unspecified
        ),
        [DateTime]::UtcNow.AddSeconds(10).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    )) {
        $invalidControl = @{} + $common
        $invalidControl.ControlValidUntilUtc = $validUntil
        Assert-CgceThrows "CGCE-OPS-CONTROL-EXPIRED" {
            Invoke-CgceChildProcess @invalidControl -TimeoutSeconds 30
        }
    }
}

Invoke-CgceTest "child process implementation uses only bounded waits and a final identity sweep" {
    $definition = (Get-Command "Invoke-CgceChildProcess").Definition
    Assert-CgceEqual $false $definition.Contains(".WaitForExit()")
    Assert-CgceEqual $false $definition.Contains(
        'WaitForExit($remainingMilliseconds)'
    )
    Assert-CgceEqual $true $definition.Contains(
        'WaitForExit($waitSliceMilliseconds)'
    )
    Assert-CgceEqual $true $definition.Contains(
        "Assert-CgceObservedProcessesTerminated"
    )
    Assert-CgceEqual $true $definition.Contains(
        '$null = & $PreLaunchValidation $launchWrite.checksum'
    )
    Assert-CgceEqual $false $definition.Contains(
        "-ArgumentList `$Arguments"
    )
    Assert-CgceEqual $true $definition.Contains(
        '["ArgumentList"] = [string[]]@($nativeCommandLine)'
    )
    Assert-CgceEqual $true $definition.Contains("[Diagnostics.Stopwatch]::StartNew()")
}

Invoke-CgceTest "child completion rejects elapsed timeout and control deadlines" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $elapsed = [pscustomobject]@{
        Elapsed = [pscustomobject]@{
            TotalMilliseconds = [double]30001
        }
    }
    Assert-CgceThrows "CGCE-OPS-PROCESS-TIMEOUT" {
        & $module {
            param($Clock)
            Assert-CgceProcessCompletedWithinDeadline `
                -Stopwatch $Clock `
                -TimeoutSeconds 30 `
                -ControlDeadlineUtc ([DateTime]::UtcNow.AddMinutes(5))
        } $elapsed
    }
    $withinTimeout = [pscustomobject]@{
        Elapsed = [pscustomobject]@{
            TotalMilliseconds = [double]1
        }
    }
    Assert-CgceThrows "CGCE-OPS-CONTROL-EXPIRED" {
        & $module {
            param($Clock)
            Assert-CgceProcessCompletedWithinDeadline `
                -Stopwatch $Clock `
                -TimeoutSeconds 30 `
                -ControlDeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
        } $withinTimeout
    }
}

Invoke-CgceTest "Windows native quoting survives an actual argv capture process" {
    $base = New-CgceRuntimeTestRoot
    try {
        $className = "CgceArgvCapture" + [guid]::NewGuid().ToString("N")
        $helper = Join-Path $base "argv-capture.exe"
        $output = Join-Path $base "argv.txt"
        $source = @"
using System;
using System.IO;
using System.Text;
public static class $className {
    public static int Main(string[] args) {
        if (args.Length < 1) return 64;
        string[] lines = new string[args.Length - 1];
        for (int index = 1; index < args.Length; index++) {
            lines[index - 1] = Convert.ToBase64String(
                Encoding.UTF8.GetBytes(args[index])
            );
        }
        File.WriteAllLines(args[0], lines, new UTF8Encoding(false));
        return 0;
    }
}
"@
        $null = Add-Type `
            -TypeDefinition $source `
            -Language CSharp `
            -OutputAssembly $helper `
            -OutputType ConsoleApplication
        $expected = [string[]]@(
            "",
            "has space",
            'embedded"quote',
            "trailing\",
            "&|<>^"
        )
        $nativeArguments = [string[]]@($output) + $expected
        $commandLine = & (Get-Module "CgceDiscovery.Runtime") {
            param($Values)
            ConvertTo-CgceWindowsCommandLine -Arguments $Values
        } $nativeArguments
        $process = Start-Process `
            -FilePath $helper `
            -ArgumentList $commandLine `
            -WorkingDirectory $base `
            -PassThru
        if (-not $process.WaitForExit(30000)) {
            throw "CGCE-TEST argv capture timed out"
        }
        Assert-CgceEqual 0 $process.ExitCode
        $actual = [string[]]@(
            foreach ($line in [System.IO.File]::ReadAllLines($output)) {
                [System.Text.Encoding]::UTF8.GetString(
                    [Convert]::FromBase64String($line)
                )
            }
        )
        Assert-CgceEqual `
            ([string]::Join("`0", $expected)) `
            ([string]::Join("`0", $actual))
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "zero arguments omit ArgumentList and oversized commands never launch" {
    $base = New-CgceRuntimeTestRoot
    try {
        $className = "CgceZeroArg" + [guid]::NewGuid().ToString("N")
        $helper = Join-Path $base "zero-arg.exe"
        $marker = Join-Path $base "launched.txt"
        $source = @"
using System;
using System.IO;
public static class $className {
    public static int Main(string[] args) {
        File.WriteAllText("launched.txt", "launched");
        return args.Length == 0 ? 0 : 65;
    }
}
"@
        $null = Add-Type `
            -TypeDefinition $source `
            -Language CSharp `
            -OutputAssembly $helper `
            -OutputType ConsoleApplication
        $checksum = Get-CgceRuntimeTestSha256 $helper
        $controlValidUntil = [DateTime]::UtcNow.AddMinutes(5)

        $zeroRunId = "r-11111111111111111111111111111111"
        $zeroRoot = Join-Path $base "$zeroRunId\receipts\process"
        New-Item -ItemType Directory -Path $zeroRoot -Force | Out-Null
        $zeroRun = Invoke-CgceChildProcess `
            -Executable $helper `
            -ExpectedExecutableChecksum $checksum `
            -AllowedExecutablePaths @($helper) `
            -Arguments ([string[]]@()) `
            -ReceiptRoot $zeroRoot `
            -TimeoutSeconds 30 `
            -PreLaunchValidation {} `
            -ControlValidUntilUtc $controlValidUntil
        Assert-CgceEqual 0 $zeroRun.result.exit_code
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath $marker -PathType Leaf)
        $zeroLaunch = Read-CgceJsonObject `
            -Path (Join-Path $zeroRoot "000-launch.json")
        Assert-CgceEqual 0 $zeroLaunch.argument_count

        [System.IO.File]::Delete($marker)
        $boundedRunId = "r-22222222222222222222222222222222"
        $boundedRoot = Join-Path $base "$boundedRunId\receipts\process"
        New-Item -ItemType Directory -Path $boundedRoot -Force | Out-Null
        $oversized = [string[]]@(
            for ($index = 0; $index -lt 8; $index += 1) {
                "x" * 4096
            }
        )
        Assert-CgceThrows "CGCE-OPS-ARGUMENT" {
            Invoke-CgceChildProcess `
                -Executable $helper `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($helper) `
                -Arguments $oversized `
                -ReceiptRoot $boundedRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
        Assert-CgceEqual $false (Test-Path -LiteralPath $marker)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem -LiteralPath $boundedRoot -Force).Count
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "final sweep descendants re-enter bounded monitoring until terminated" {
    $base = New-CgceRuntimeTestRoot
    try {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "CGCE-TEST ComSpec is required on Windows"
        }
        $runId = "r-44444444444444444444444444444444"
        $receiptRoot = Join-Path $base "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $executable = [System.IO.Path]::GetFullPath($env:ComSpec)
        $checksum = Get-CgceRuntimeTestSha256 $executable
        $snapshots = [pscustomobject]@{ Count = 0 }
        $childPid = [int64]420045
        Set-CgceRuntimeTestProcessRecordsSeam {
            $snapshots.Count += 1
            if ($snapshots.Count -eq 1) {
                Wait-CgceRuntimeTestReceiptRootExit $receiptRoot
                return @()
            }
            if ($snapshots.Count -eq 2) {
                $rootReceipt = Read-CgceJsonObject `
                    -Path (Join-Path $receiptRoot "001-pid.json")
                return @([pscustomobject]@{
                    ProcessId = $childPid
                    ParentProcessId = [int64]$rootReceipt.pid
                    ExecutablePath = $executable
                    CreationTimeFileTimeUtc = (
                        [int64]$rootReceipt.creation_time_filetime_utc + 1
                    )
                })
            }
            return @()
        }.GetNewClosure()

        $completed = Invoke-CgceChildProcess `
            -Executable $executable `
            -ExpectedExecutableChecksum $checksum `
            -AllowedExecutablePaths @($executable) `
            -Arguments @("/d", "/c", "exit", "/b", "0") `
            -ReceiptRoot $receiptRoot `
            -TimeoutSeconds 30 `
            -PreLaunchValidation {} `
            -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))

        Assert-CgceEqual 0 $completed.result.exit_code
        Assert-CgceEqual $true ($snapshots.Count -ge 4)
        Assert-CgceEqual 2 @($completed.result.observed_processes).Count
        Assert-CgceEqual `
            $childPid `
            ([int64]$completed.result.observed_processes[1].pid)
        Assert-CgceEqual $true `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "002-pid.json") `
                -PathType Leaf)
        Assert-CgceEqual $true `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "999-result.json") `
                -PathType Leaf)
    } finally {
        Set-CgceRuntimeTestProcessRecordsSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "stale pre-parent ParentPID records never create receipts" {
    $base = New-CgceRuntimeTestRoot
    try {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "CGCE-TEST ComSpec is required on Windows"
        }
        $runId = "r-55555555555555555555555555555555"
        $receiptRoot = Join-Path $base "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $executable = [System.IO.Path]::GetFullPath($env:ComSpec)
        $checksum = Get-CgceRuntimeTestSha256 $executable
        $snapshots = [pscustomobject]@{ Count = 0 }
        $stalePid = [int64]420046
        Set-CgceRuntimeTestProcessRecordsSeam {
            $snapshots.Count += 1
            if ($snapshots.Count -eq 1) {
                Wait-CgceRuntimeTestReceiptRootExit $receiptRoot
                $rootReceipt = Read-CgceJsonObject `
                    -Path (Join-Path $receiptRoot "001-pid.json")
                return @([pscustomobject]@{
                    ProcessId = $stalePid
                    ParentProcessId = [int64]$rootReceipt.pid
                    ExecutablePath = $executable
                    CreationTimeFileTimeUtc = (
                        [int64]$rootReceipt.creation_time_filetime_utc - 1
                    )
                })
            }
            return @()
        }.GetNewClosure()

        $completed = Invoke-CgceChildProcess `
            -Executable $executable `
            -ExpectedExecutableChecksum $checksum `
            -AllowedExecutablePaths @($executable) `
            -Arguments @("/d", "/c", "exit", "/b", "0") `
            -ReceiptRoot $receiptRoot `
            -TimeoutSeconds 30 `
            -PreLaunchValidation {} `
            -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))

        Assert-CgceEqual 0 $completed.result.exit_code
        Assert-CgceEqual 1 @($completed.result.observed_processes).Count
        Assert-CgceEqual $false `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "002-pid.json"))
        Assert-CgceEqual $true `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "999-result.json") `
                -PathType Leaf)
    } finally {
        Set-CgceRuntimeTestProcessRecordsSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "reused live PID identity leaves a durable recovery barrier" {
    $base = New-CgceRuntimeTestRoot
    try {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "CGCE-TEST ComSpec is required on Windows"
        }
        $runId = "r-66666666666666666666666666666666"
        $receiptRoot = Join-Path $base "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $executable = [System.IO.Path]::GetFullPath($env:ComSpec)
        $checksum = Get-CgceRuntimeTestSha256 $executable
        $reusedPid = [int64]420047
        Set-CgceRuntimeTestProcessRecordsSeam {
            $rootReceipt = Read-CgceJsonObject `
                -Path (Join-Path $receiptRoot "001-pid.json")
            return @(
                [pscustomobject]@{
                    ProcessId = $reusedPid
                    ParentProcessId = [int64]$rootReceipt.pid
                    ExecutablePath = $executable
                    CreationTimeFileTimeUtc = (
                        [int64]$rootReceipt.creation_time_filetime_utc + 1
                    )
                },
                [pscustomobject]@{
                    ProcessId = $reusedPid
                    ParentProcessId = [int64]$rootReceipt.pid
                    ExecutablePath = "C:\Unexpected\reused.exe"
                    CreationTimeFileTimeUtc = (
                        [int64]$rootReceipt.creation_time_filetime_utc + 2
                    )
                }
            )
        }.GetNewClosure()

        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))
        }

        $barrierPath = Join-Path `
            $receiptRoot `
            "manual-recovery-required.json"
        $barrier = Read-CgceJsonObject -Path $barrierPath
        $rootReceipt = Read-CgceJsonObject `
            -Path (Join-Path $receiptRoot "001-pid.json")
        $firstChildPath = Join-Path $receiptRoot "002-pid.json"
        Assert-CgceEqual "IDENTITY_UNREADABLE" $barrier.reason
        Assert-CgceEqual $reusedPid ([int64]$barrier.pid)
        Assert-CgceEqual `
            ([int64]$rootReceipt.pid) `
            ([int64]$barrier.parent_pid)
        Assert-CgceEqual `
            (Get-CgceRuntimeTestSha256 $firstChildPath) `
            $barrier.previous_receipt_sha256
        Assert-CgceEqual $true `
            (Test-Path `
                -LiteralPath $firstChildPath `
                -PathType Leaf)
        Assert-CgceEqual $false `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "003-pid.json"))
        Assert-CgceEqual $false `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "999-result.json"))

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @($executable) `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Set-CgceRuntimeTestProcessRecordsSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "process crash seams preserve exact immutable partial receipts" {
    foreach ($case in @(
        [pscustomobject]@{
            Point = "after-process-start"
            ExpectedPidReceipts = 0
        },
        [pscustomobject]@{
            Point = "after-pid-1"
            ExpectedPidReceipts = 1
        },
        [pscustomobject]@{
            Point = "after-pid-2"
            ExpectedPidReceipts = 2
        },
        [pscustomobject]@{
            Point = "before-result"
            ExpectedPidReceipts = 1
        }
    )) {
        $base = New-CgceRuntimeTestRoot
        try {
            if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
                throw "CGCE-TEST ComSpec is required on Windows"
            }
            $runId = "r-33333333333333333333333333333333"
            $receiptRoot = Join-Path $base "$runId\receipts\process"
            New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
            $executable = [System.IO.Path]::GetFullPath($env:ComSpec)
            $checksum = Get-CgceRuntimeTestSha256 $executable
            if ($case.Point -ceq "after-pid-2") {
                Set-CgceRuntimeTestProcessRecordsSeam {
                    $rootReceipt = Read-CgceJsonObject `
                        -Path (Join-Path $receiptRoot "001-pid.json")
                    return @([pscustomobject]@{
                        ProcessId = 420044
                        ParentProcessId = [int64]$rootReceipt.pid
                        ExecutablePath = $executable
                        CreationTimeFileTimeUtc = (
                            [int64]$rootReceipt.creation_time_filetime_utc + 1
                        )
                    })
                }.GetNewClosure()
            }
            Set-CgceRuntimeTestProcessCrashSeam {
                param($Point)
                if ($Point -ceq $case.Point) {
                    throw "CGCE-TEST-PROCESS-CRASH $Point"
                }
            }.GetNewClosure()
            Assert-CgceThrows "CGCE-TEST-PROCESS-CRASH" {
                Invoke-CgceChildProcess `
                    -Executable $executable `
                    -ExpectedExecutableChecksum $checksum `
                    -AllowedExecutablePaths @($executable) `
                    -Arguments @("/d", "/c", "exit", "/b", "0") `
                    -ReceiptRoot $receiptRoot `
                    -TimeoutSeconds 30 `
                    -PreLaunchValidation {} `
                    -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))
            }
            Assert-CgceEqual $true `
                (Test-Path `
                    -LiteralPath (Join-Path $receiptRoot "000-launch.json") `
                    -PathType Leaf)
            Assert-CgceEqual `
                $case.ExpectedPidReceipts `
                @(Get-ChildItem `
                    -LiteralPath $receiptRoot `
                    -Filter "*-pid.json").Count
            $expectedNames = @("000-launch.json")
            for ($sequence = 1;
                $sequence -le $case.ExpectedPidReceipts;
                $sequence += 1) {
                $expectedNames += (
                    $sequence.ToString("000") + "-pid.json"
                )
            }
            $actualNames = @(
                Get-ChildItem -LiteralPath $receiptRoot -Force |
                    ForEach-Object { $_.Name } |
                    Sort-Object
            )
            Assert-CgceEqual `
                ([string]::Join(",", $expectedNames)) `
                ([string]::Join(",", $actualNames))
            Assert-CgceEqual $false `
                (Test-Path `
                    -LiteralPath (Join-Path $receiptRoot "999-result.json"))
            Assert-CgceEqual $false `
                (Test-Path `
                    -LiteralPath (
                        Join-Path $receiptRoot "manual-recovery-required.json"
                    ))
        } finally {
            Set-CgceRuntimeTestProcessCrashSeam $null
            Set-CgceRuntimeTestProcessRecordsSeam $null
            Remove-Item -LiteralPath $base -Recurse -Force
        }
    }
}

Invoke-CgceTest "child process receipts never persist plaintext arguments" {
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
        $controlValidUntil = [DateTime]::UtcNow.AddMinutes(5).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum ("f" * 64) `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "7") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem -LiteralPath $receiptRoot -Force).Count
        $run = Invoke-CgceChildProcess `
            -Executable $executable `
            -ExpectedExecutableChecksum $checksum `
            -AllowedExecutablePaths @($executable) `
            -Arguments @("/d", "/c", "exit", "/b", "7") `
            -ReceiptRoot $receiptRoot `
            -TimeoutSeconds 30 `
            -PreLaunchValidation {} `
            -ControlValidUntilUtc $controlValidUntil

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
            "control_valid_until_utc",
            "previous_receipt_sha256"
        )
        Assert-CgceEqual "cgce_windows_discovery_process_launch" $launch.kind
        Assert-CgceEqual 0 $launch.sequence
        Assert-CgceEqual 5 $launch.argument_count
        Assert-CgceEqual $controlValidUntil $launch.control_valid_until_utc
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
        Assert-CgceEqual 0 $pidReceipt.parent_pid
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
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "child launch semantically reads back intent before Start-Process" {
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
        $controlValidUntil = [DateTime]::UtcNow.AddMinutes(5).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        Set-CgceRuntimeTestLaunchReceiptSeam {
            param($Path)
            $receipt = Read-CgceJsonObject -Path $Path
            $receipt.argument_count = 99
            Write-CgceRuntimeTestUtf8 `
                -Path $Path `
                -Text ($receipt | ConvertTo-Json -Depth 12)
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-RECEIPT" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "000-launch.json"))
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "001-pid.json"))
    } finally {
        Set-CgceRuntimeTestLaunchReceiptSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "child launch invokes final pre-launch authority before Start-Process" {
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
        $validation = {
            param($LaunchChecksum)
            $launchPath = Join-Path $receiptRoot "000-launch.json"
            if ($LaunchChecksum -cne
                (Get-CgceRuntimeTestSha256 $launchPath)) {
                throw "CGCE-TEST-PRELAUNCH-CHECKSUM"
            }
            if (-not (Test-Path `
                    -LiteralPath $launchPath `
                    -PathType Leaf)) {
                throw "CGCE-TEST-PRELAUNCH-MISSING-INTENT"
            }
            throw "CGCE-TEST-PRELAUNCH-BLOCKED"
        }.GetNewClosure()
        Assert-CgceThrows "CGCE-TEST-PRELAUNCH-BLOCKED" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation $validation `
                -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))
        }
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "001-pid.json"))
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "child launch rehashes the executable after intent read-back" {
    $base = New-CgceRuntimeTestRoot
    try {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "CGCE-TEST ComSpec is required on Windows"
        }
        $runId = "r-0123456789abcdef0123456789abcdef"
        $receiptRoot = Join-Path $base "$runId\receipts\process"
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $executable = Join-Path $base "synthetic-cmd.exe"
        $null = Copy-CgceFileVerified `
            -Source ([System.IO.Path]::GetFullPath($env:ComSpec)) `
            -Destination $executable
        $checksum = Get-CgceRuntimeTestSha256 $executable
        $controlValidUntil = [DateTime]::UtcNow.AddMinutes(5)
        Set-CgceRuntimeTestLaunchReceiptSeam {
            param($Path)
            [System.IO.File]::AppendAllText($executable, "drift")
        }.GetNewClosure()
        Assert-CgceThrows "CGCE-OPS-CHECKSUM" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "000-launch.json"))
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "001-pid.json"))
    } finally {
        Set-CgceRuntimeTestLaunchReceiptSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "unlisted descendant receipt is durable before launch fails" {
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
        $controlValidUntil = [DateTime]::UtcNow.AddMinutes(5).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        Set-CgceRuntimeTestProcessRecordsSeam {
            $rootReceipt = Read-CgceJsonObject `
                -Path (Join-Path $receiptRoot "001-pid.json")
            return @([pscustomobject]@{
                ProcessId = 420042
                ParentProcessId = [int64]$rootReceipt.pid
                ExecutablePath = "C:\Unexpected\child.exe"
                CreationTimeFileTimeUtc = (
                    [int64]$rootReceipt.creation_time_filetime_utc + 1
                )
            })
        }.GetNewClosure()
        Assert-CgceThrows "CGCE-OPS-PROCESS-UNLISTED" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc $controlValidUntil
        }
        $unlisted = Read-CgceJsonObject `
            -Path (Join-Path $receiptRoot "002-pid.json")
        Assert-CgceEqual "C:\Unexpected\child.exe" $unlisted.executable_path
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "999-result.json"))
    } finally {
        Set-CgceRuntimeTestProcessRecordsSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "unreadable descendant leaves a durable manual-recovery barrier" {
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
        $snapshotCount = 0
        Set-CgceRuntimeTestProcessRecordsSeam {
            $snapshotCount += 1
            $rootReceipt = Read-CgceJsonObject `
                -Path (Join-Path $receiptRoot "001-pid.json")
            return @([pscustomobject]@{
                ProcessId = 420043
                ParentProcessId = [int64]$rootReceipt.pid
                ExecutablePath = $(if ($snapshotCount -eq 1) {
                    $executable
                } else {
                    $null
                })
                CreationTimeFileTimeUtc = (
                    [int64]$rootReceipt.creation_time_filetime_utc + 1
                )
            })
        }.GetNewClosure()
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))
        }
        $barrierPath = Join-Path $receiptRoot "manual-recovery-required.json"
        $barrier = Read-CgceJsonObject -Path $barrierPath
        Assert-CgceEqual `
            "cgce_windows_discovery_process_manual_recovery" `
            $barrier.kind
        Assert-CgceEqual "IDENTITY_UNREADABLE" $barrier.reason
        Assert-CgceEqual 420043 $barrier.pid
        Assert-CgceEqual $true `
            (Test-Path `
                -LiteralPath (Join-Path $receiptRoot "002-pid.json") `
                -PathType Leaf)

        Set-CgceRuntimeTestActivitySeam {
            New-CgceRuntimeActivitySnapshot -Processes @() -Tcp @() -Udp @()
        }
        Assert-CgceThrows "CGCE-OPS-MANUAL-RECOVERY" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @($executable) `
                -Ports @(8211) `
                -ReceiptRoot $receiptRoot
        }
    } finally {
        Set-CgceRuntimeTestActivitySeam $null
        Set-CgceRuntimeTestProcessRecordsSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "root PID receipt is durable before CIM verification fails" {
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
        Set-CgceRuntimeTestRootProcessRecordSeam {
            throw "synthetic CIM access denied"
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
            Invoke-CgceChildProcess `
                -Executable $executable `
                -ExpectedExecutableChecksum $checksum `
                -AllowedExecutablePaths @($executable) `
                -Arguments @("/d", "/c", "exit", "/b", "0") `
                -ReceiptRoot $receiptRoot `
                -TimeoutSeconds 30 `
                -PreLaunchValidation {} `
                -ControlValidUntilUtc ([DateTime]::UtcNow.AddMinutes(5))
        }
        $rootReceipt = Read-CgceJsonObject `
            -Path (Join-Path $receiptRoot "001-pid.json")
        Assert-CgceEqual $executable $rootReceipt.executable_path
        Assert-CgceEqual $false `
            (Test-Path -LiteralPath (Join-Path $receiptRoot "999-result.json"))
    } finally {
        Set-CgceRuntimeTestRootProcessRecordSeam $null
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

Invoke-CgceTest "short-lived root process uses immediate Process identity when CIM returns null" {
    $module = Get-Module "CgceDiscovery.Runtime"
    try {
        Set-CgceRuntimeTestRootProcessRecordSeam { return $null }
        $start = [DateTime]::SpecifyKind(
            [DateTime]::Parse("2026-07-23T01:02:03Z"),
            [DateTimeKind]::Utc
        )
        $process = [pscustomobject]@{ Id = 73; StartTime = $start }
        $record = & $module {
            param($Value, $Path)
            Get-CgceRootProcessRecord -Process $Value -CanonicalPath $Path
        } $process "D:\PalServer\PalServer.exe"
        Assert-CgceEqual 73 $record.ProcessId
        Assert-CgceEqual "D:\PalServer\PalServer.exe" $record.ExecutablePath
        Assert-CgceEqual $start.ToFileTimeUtc() `
            $record.CreationTimeFileTimeUtc
    } finally {
        Set-CgceRuntimeTestRootProcessRecordSeam $null
    }
}

Invoke-CgceTest "root process CIM access failure never degrades to fallback identity" {
    $module = Get-Module "CgceDiscovery.Runtime"
    try {
        Set-CgceRuntimeTestRootProcessRecordSeam {
            throw "synthetic CIM access denied"
        }
        $process = [pscustomobject]@{
            Id = 73
            StartTime = [DateTime]::Parse("2026-07-23T01:02:03Z")
        }
        Assert-CgceThrows "CGCE-OPS-PROCESS-QUERY" {
            & $module {
                param($Value, $Path)
                Get-CgceRootProcessRecord -Process $Value -CanonicalPath $Path
            } $process "D:\PalServer\PalServer.exe"
        }
    } finally {
        Set-CgceRuntimeTestRootProcessRecordSeam $null
    }
}

Invoke-CgceTest "runtime module exports only its approved Task 3 surface" {
    $module = Get-Module "CgceDiscovery.Runtime"
    $actual = @($module.ExportedFunctions.Keys | Sort-Object)
    $expected = @(
        "Assert-CgceNoForeignRunArtifacts",
        "Assert-CgceNoServerActivity",
        "Assert-CgceInventoryProbeStaged",
        "Assert-CgceServerArguments",
        "Enable-CgceInventoryProbe",
        "Invoke-CgceChildProcess",
        "Restore-CgceInventoryProbe"
    ) | Sort-Object
    Assert-CgceEqual `
        ([string]::Join(",", $expected)) `
        ([string]::Join(",", $actual))
}
