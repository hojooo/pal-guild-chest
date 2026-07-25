Import-Module "$PSScriptRoot\..\..\tools\windows-discovery\CgceDiscovery.Common.psm1" -Force

function Write-CgceLifecycleUtf8([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-CgceLifecycleAvailableListenerPort(
    [int[]]$ExcludedPorts = @()
) {
    for ($attempt = 0; $attempt -lt 32; $attempt += 1) {
        $tcp = $null
        $udp = $null
        try {
            $tcp = New-Object Net.Sockets.TcpListener `
                ([Net.IPAddress]::Loopback), 0
            $tcp.Start()
            $port = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port
            if ($ExcludedPorts -contains $port) {
                continue
            }
            $udp = New-Object Net.Sockets.UdpClient
            $endpoint = New-Object Net.IPEndPoint `
                ([Net.IPAddress]::Loopback), $port
            $udp.Client.Bind($endpoint)
            return $port
        } catch {
            continue
        } finally {
            if ($null -ne $udp) { $udp.Dispose() }
            if ($null -ne $tcp) { $tcp.Stop() }
        }
    }
    throw "CGCE-TEST isolated TCP/UDP listener port allocation failed"
}

function Get-CgceLifecycleHandoffPaths {
    return @(
        "tests/windows/Contract.Tests.ps1",
        "tests/windows/Files.Tests.ps1",
        "tests/windows/fixtures/FakePalServer.cmd",
        "tests/windows/Lifecycle.Tests.ps1",
        "tests/windows/Run-CgceDiscoverySmokeTests.ps1",
        "tests/windows/Run-CgceDiscoveryTests.ps1",
        "tests/windows/Runtime.Tests.ps1",
        "tests/windows/Smoke.Tests.ps1",
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
}

function New-CgceSyntheticFixture {
    $base = Join-Path $env:TEMP ("cgce-lifecycle-" + [guid]::NewGuid().ToString("N"))
    $serverRoot = Join-Path $base "server"
    $savedPath = Join-Path $serverRoot "Pal\Saved"
    $ue4ssRoot = Join-Path $serverRoot "Pal\Binaries\Win64"
    $modsRoot = Join-Path $ue4ssRoot "Mods"
    $runRoot = Join-Path $base "runs"
    $outputRoot = Join-Path $base "exports"
    $handoffRoot = Join-Path $base "handoff"
    $runId = "r-" + [guid]::NewGuid().ToString("N")
    New-Item -ItemType Directory -Path $savedPath -Force | Out-Null
    New-Item -ItemType Directory -Path $modsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    New-Item -ItemType Directory -Path $outputRoot | Out-Null
    New-Item -ItemType Directory -Path $handoffRoot | Out-Null
    Write-CgceLifecycleUtf8 (Join-Path $savedPath "WorldOption.sav") "synthetic-world"
    New-Item -ItemType Directory -Path (Join-Path $savedPath "Players") | Out-Null
    Write-CgceLifecycleUtf8 (Join-Path $savedPath "Players\synthetic.sav") "synthetic-player"
    Write-CgceLifecycleUtf8 (Join-Path $ue4ssRoot "UE4SS.dll") "synthetic-ue4ss"
    Write-CgceLifecycleUtf8 (Join-Path $modsRoot "mods.txt") "BPModLoaderMod : 1`r`n"

    $serverExecutable = Join-Path $serverRoot "PalServer.exe"
    $cmd = Join-Path $env:SystemRoot "System32\cmd.exe"
    [System.IO.File]::Copy($cmd, $serverExecutable, $false)

    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $handoffRecords = New-Object 'System.Collections.Generic.List[string]'
    $handoffPaths = @(Get-CgceLifecycleHandoffPaths)
    [Array]::Sort($handoffPaths, [StringComparer]::Ordinal)
    foreach ($relative in $handoffPaths) {
        $destination = Join-Path $handoffRoot ($relative -replace '/', '\')
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $source = Join-Path $repositoryRoot ($relative -replace '/', '\')
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            [System.IO.File]::Copy($source, $destination, $false)
        } else {
            Write-CgceLifecycleUtf8 $destination ("synthetic " + $relative)
        }
        $handoffRecords.Add((Get-CgceSha256 $destination) + "  " + $relative)
    }
    $sourceManifestPath = Join-Path $handoffRoot "source-manifest.sha256"
    Write-CgceLifecycleUtf8 `
        $sourceManifestPath `
        (($handoffRecords.ToArray() -join "`n") + "`n")

    $bundleSha = "a" * 64
    $listenerPort = Get-CgceLifecycleAvailableListenerPort
    $verifiedAt = [DateTime]::UtcNow.AddMinutes(-1)
    $validUntil = $verifiedAt.AddHours(3)
    $control = [pscustomobject][ordered]@{
        schema_version = "1.0"
        kind = "cgce_windows_discovery_control"
        maintenance_id = "m-" + [guid]::NewGuid().ToString("N")
        run_id = $runId
        operator = "synthetic-operator"
        server_root = $serverRoot
        palserver_executable = $serverExecutable
        server_process_paths = @($serverExecutable)
        server_process_paths_complete = $true
        ue4ss_root = $ue4ssRoot
        ue4ss_version = "3.0.1"
        ue4ss_dll_sha256 = (Get-CgceSha256 (Join-Path $ue4ssRoot "UE4SS.dll"))
        listener_ports = @($listenerPort)
        production_restart_disabled = $true
        external_access_blocked = $true
        players_disconnected = $true
        bundle_checksum = $bundleSha
        verified_at_utc = $verifiedAt.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
        valid_until_utc = $validUntil.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    $controlPath = Join-Path $base "control-evidence.json"
    Write-CgceLifecycleUtf8 $controlPath ($control | ConvertTo-Json -Depth 8)
    $paths = New-CgceRunPaths `
        -ServerRoot $serverRoot -SavedPath $savedPath `
        -Ue4ssRoot $ue4ssRoot -RunRoot $runRoot -RunId $runId
    return [pscustomobject]@{
        Base = $base
        ServerRoot = $serverRoot
        SavedPath = $savedPath
        Ue4ssRoot = $ue4ssRoot
        ServerExecutable = $serverExecutable
        RunRoot = $runRoot
        OutputRoot = $outputRoot
        RunId = $runId
        ControlListenerPort = $listenerPort
        HandoffRoot = $handoffRoot
        SourceManifestPath = $sourceManifestPath
        SourceManifestSha = (Get-CgceSha256 $sourceManifestPath)
        ControlPath = $controlPath
        ControlSha = (Get-CgceSha256 $controlPath)
        BundleSha = $bundleSha
        Paths = $paths
        OriginalInventory = @(Get-CgceTreeInventory -Root $savedPath)
        PrepareScript = (Join-Path `
            $handoffRoot `
            "tools\windows-discovery\Prepare-CgceDiscovery.ps1")
        InvokeScript = (Join-Path `
            $handoffRoot `
            "tools\windows-discovery\Invoke-CgceDiscovery.ps1")
        RestoreScript = (Join-Path `
            $handoffRoot `
            "tools\windows-discovery\Restore-CgceProduction.ps1")
        ExportScript = (Join-Path `
            $handoffRoot `
            "tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1")
        FakeServerScript = (Join-Path `
            $handoffRoot `
            "tests\windows\fixtures\FakePalServer.cmd")
        RepositoryPrepareScript = (Join-Path `
            $repositoryRoot `
            "tools\windows-discovery\Prepare-CgceDiscovery.ps1")
        RepositoryInvokeScript = (Join-Path `
            $repositoryRoot `
            "tools\windows-discovery\Invoke-CgceDiscovery.ps1")
        RepositoryRestoreScript = (Join-Path `
            $repositoryRoot `
            "tools\windows-discovery\Restore-CgceProduction.ps1")
        RepositoryExportScript = (Join-Path `
            $repositoryRoot `
            "tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1")
    }
}

function ConvertTo-CgceLifecycleSingleQuoted([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-CgcePrepareChild(
    $Fixture,
    [string]$ModuleSetup = ""
) {
    $stderrPath = Join-Path $Fixture.Base ("prepare-stderr-" + [guid]::NewGuid().ToString("N"))
    $entryScript = $Fixture.PrepareScript
    if (-not [string]::IsNullOrWhiteSpace($ModuleSetup)) {
        $entryScript = Join-Path $Fixture.Base (
            "prepare-wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1"
        )
        $toolRoot = Join-Path $Fixture.HandoffRoot "tools\windows-discovery"
        $wrapper = @(
            '$ErrorActionPreference = "Stop"'
            ('$commonModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "CgceDiscovery.Common.psm1"
                )) + ' -Global -PassThru')
            ('$contractModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Contract.psm1"
                )) + ' -Global -PassThru')
            ('$filesModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Files.psm1"
                )) + ' -Global -PassThru')
            ('$runtimeModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Runtime.psm1"
                )) + ' -Global -PassThru')
            $ModuleSetup
            ('& ' + (ConvertTo-CgceLifecycleSingleQuoted $Fixture.PrepareScript) +
                ' @args')
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        Write-CgceLifecycleUtf8 -Path $entryScript -Text ($wrapper + "`r`n")
    }
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryScript,
        "-ServerRoot", $Fixture.ServerRoot,
        "-SavedPath", $Fixture.SavedPath,
        "-Ue4ssRoot", $Fixture.Ue4ssRoot,
        "-ServerExecutable", $Fixture.ServerExecutable,
        "-RunRoot", $Fixture.RunRoot,
        "-RunId", $Fixture.RunId,
        "-HandoffRoot", $Fixture.HandoffRoot,
        "-SourceManifestPath", $Fixture.SourceManifestPath,
        "-ControlEvidencePath", $Fixture.ControlPath,
        "-ControlEvidenceSha256", $Fixture.ControlSha,
        "-BundleSha256", $Fixture.BundleSha
    )
    $stdout = @(& "$PSHOME\powershell.exe" @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($stderrPath)
    } else {
        ""
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function New-CgcePreparedFixture(
    [string]$Mode = "success",
    [bool]$IncludeSleeperInAllowlist = $false,
    [bool]$IncludeLauncherInAllowlist = $false,
    [bool]$IncludeListenerInAllowlist = $false
) {
    $fixture = New-CgceSyntheticFixture
    $runtimeSleeper = Join-Path `
        $fixture.ServerRoot `
        "cgce-fake-sleeper.exe"
    $runtimeLauncher = Join-Path `
        $fixture.ServerRoot `
        "cgce-fake-launcher.exe"
    $runtimeListener = Join-Path `
        $fixture.ServerRoot `
        "cgce-fake-listener.exe"
    $additionalProcessPaths = New-Object `
        'System.Collections.Generic.List[string]'
    if ($IncludeSleeperInAllowlist) {
        $additionalProcessPaths.Add($runtimeSleeper)
    }
    if ($IncludeLauncherInAllowlist) {
        $additionalProcessPaths.Add($runtimeLauncher)
    }
    if ($IncludeListenerInAllowlist) {
        $additionalProcessPaths.Add($runtimeListener)
    }
    $listenerPort = $null
    if ($IncludeListenerInAllowlist) {
        $listenerPort = Get-CgceLifecycleAvailableListenerPort `
            -ExcludedPorts @($fixture.ControlListenerPort)
    }
    if ($additionalProcessPaths.Count -gt 0 -or $null -ne $listenerPort) {
        $control = Read-CgceJsonObject -Path $fixture.ControlPath
        $control.server_process_paths = [object[]](
            @($control.server_process_paths) +
                @($additionalProcessPaths.ToArray())
        )
        if ($null -ne $listenerPort) {
            $control.listener_ports = [object[]](
                @($control.listener_ports) + @($listenerPort)
            )
        }
        Write-CgceLifecycleUtf8 `
            -Path $fixture.ControlPath `
            -Text ($control | ConvertTo-Json -Depth 8)
        $fixture.ControlSha = Get-CgceSha256 $fixture.ControlPath
    }
    $prepared = Invoke-CgcePrepareChild -Fixture $fixture
    if ($prepared.ExitCode -ne 0 -or
        @($prepared.Stdout).Count -ne 1 -or
        $prepared.Stdout[0] -cne
            "CGCE_WINDOWS_DISCOVERY_OK PROBE_STAGED $($fixture.RunId)" -or
        -not [string]::IsNullOrEmpty($prepared.Stderr)) {
        throw "CGCE-TEST synthetic prepare failed"
    }
    $runtimeFakeServer = Join-Path `
        $fixture.ServerRoot `
        "cgce-fake-server.cmd"
    [System.IO.File]::Copy(
        $fixture.FakeServerScript,
        $runtimeFakeServer,
        $false
    )
    $systemPing = Join-Path $env:SystemRoot "System32\ping.exe"
    if (-not (Test-Path -LiteralPath $systemPing -PathType Leaf)) {
        throw "CGCE-TEST system ping fixture is missing"
    }
    [System.IO.File]::Copy($systemPing, $runtimeSleeper, $false)
    if ($IncludeLauncherInAllowlist) {
        [System.IO.File]::Copy(
            (Join-Path $env:SystemRoot "System32\cmd.exe"),
            $runtimeLauncher,
            $false
        )
    }
    if ($IncludeListenerInAllowlist) {
        $listenerClass = "CgceListener" +
            [guid]::NewGuid().ToString("N")
        $listenerSource = @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public static class $listenerClass {
    public static int Main(string[] args) {
        if (args.Length != 1) return 64;
        int port = Int32.Parse(args[0]);
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        try { Thread.Sleep(3000); } finally { listener.Stop(); }
        File.WriteAllText(
            "cgce-listener-exited.txt",
            "exited",
            new UTF8Encoding(false)
        );
        return 0;
    }
}
"@
        $null = Add-Type `
            -TypeDefinition $listenerSource `
            -Language CSharp `
            -OutputAssembly $runtimeListener `
            -OutputType ConsoleApplication
    }
    $grandchildScript = Join-Path `
        $fixture.ServerRoot `
        "cgce-fake-grandchild.cmd"
    Write-CgceLifecycleUtf8 `
        -Path $grandchildScript `
        -Text (
            "@echo off`r`n" +
            "cgce-fake-sleeper.exe 127.0.0.1 -n 4 > nul`r`n" +
            "exit /b %ERRORLEVEL%`r`n"
        )
    $argumentsPath = Join-Path $fixture.Base "server-arguments.json"
    $arguments = [object[]]@(
        "/d",
        "/c",
        "cgce-fake-server.cmd",
        "Pal\Binaries\Win64",
        $Mode
    )
    if ($null -ne $listenerPort) {
        $arguments = [object[]](@($arguments) + @([string]$listenerPort))
    }
    Write-CgceLifecycleUtf8 `
        -Path $argumentsPath `
        -Text ($arguments | ConvertTo-Json -Compress)
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name ArgumentsPath `
        -Value $argumentsPath
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name RuntimeFakeServer `
        -Value $runtimeFakeServer
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name RuntimeSleeper `
        -Value $runtimeSleeper
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name RuntimeLauncher `
        -Value $runtimeLauncher
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name RuntimeListener `
        -Value $runtimeListener
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name ListenerPort `
        -Value $listenerPort
    return $fixture
}

function Invoke-CgceInvokeChild(
    $Fixture,
    [int]$TimeoutSeconds = 30,
    [string]$ModuleSetup = ""
) {
    $stderrPath = Join-Path $Fixture.Base (
        "invoke-stderr-" + [guid]::NewGuid().ToString("N")
    )
    $entryScript = $Fixture.InvokeScript
    if (-not [string]::IsNullOrWhiteSpace($ModuleSetup)) {
        $entryScript = Join-Path $Fixture.Base (
            "invoke-wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1"
        )
        $toolRoot = Join-Path $Fixture.HandoffRoot "tools\windows-discovery"
        $wrapper = @(
            '$ErrorActionPreference = "Stop"'
            ('$commonModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "CgceDiscovery.Common.psm1"
                )) + ' -Global -PassThru')
            ('$contractModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Contract.psm1"
                )) + ' -Global -PassThru')
            ('$filesModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Files.psm1"
                )) + ' -Global -PassThru')
            ('$runtimeModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Runtime.psm1"
                )) + ' -Global -PassThru')
            $ModuleSetup
            ('& ' + (ConvertTo-CgceLifecycleSingleQuoted $Fixture.InvokeScript) +
                ' @args')
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        Write-CgceLifecycleUtf8 -Path $entryScript -Text ($wrapper + "`r`n")
    }
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryScript,
        "-RunRoot", $Fixture.RunRoot,
        "-RunId", $Fixture.RunId,
        "-ServerExecutable", $Fixture.ServerExecutable,
        "-ArgumentsPath", $Fixture.ArgumentsPath,
        "-TimeoutSeconds", $TimeoutSeconds
    )
    $stdout = @(& "$PSHOME\powershell.exe" @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($stderrPath)
    } else {
        ""
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Wait-CgceLifecycleServerInactive(
    $Fixture,
    [int]$Attempts = 100
) {
    for ($attempt = 0; $attempt -lt $Attempts; $attempt += 1) {
        try {
            $state = Read-CgceRunState `
                -RunRoot $Fixture.RunRoot `
                -RunId $Fixture.RunId
            Assert-CgceNoServerActivity `
                -ExecutablePaths ([string[]]$state.server_process_paths) `
                -Ports ([int[]]$state.listener_ports) `
                -ReceiptRoot $Fixture.Paths.process_receipts
            return
        } catch {
            if (-not $_.Exception.Message.StartsWith(
                    "CGCE-OPS-PROCESS-ACTIVE",
                    [StringComparison]::Ordinal
                )) {
                throw
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "CGCE-TEST synthetic server process did not exit"
}

function Update-CgceLifecycleControl(
    $Fixture,
    [scriptblock]$Mutation
) {
    $control = Read-CgceJsonObject -Path $Fixture.ControlPath
    $null = & $Mutation $control $Fixture
    Write-CgceLifecycleUtf8 `
        -Path $Fixture.ControlPath `
        -Text ($control | ConvertTo-Json -Depth 8)
    $Fixture.ControlSha = Get-CgceSha256 $Fixture.ControlPath
}

function Update-CgceLifecycleHandoffManifest($Fixture) {
    $records = New-Object 'System.Collections.Generic.List[string]'
    $paths = @(Get-CgceLifecycleHandoffPaths)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($relative in $paths) {
        $path = Join-Path $Fixture.HandoffRoot ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "CGCE-TEST handoff payload missing during manifest rebuild"
        }
        $records.Add((Get-CgceSha256 $path) + "  " + $relative)
    }
    Write-CgceLifecycleUtf8 `
        -Path $Fixture.SourceManifestPath `
        -Text (($records.ToArray() -join "`n") + "`n")
    $Fixture.SourceManifestSha = Get-CgceSha256 $Fixture.SourceManifestPath
}

function Relocate-CgceLifecycleHandoff($Fixture) {
    $sourceRoot = $Fixture.HandoffRoot
    $destinationRoot = Join-Path `
        $Fixture.Base `
        ("handoff-relocated-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $destinationRoot | Out-Null

    foreach ($relative in @(Get-CgceLifecycleHandoffPaths)) {
        $source = Join-Path $sourceRoot ($relative -replace '/', '\')
        $destination = Join-Path `
            $destinationRoot `
            ($relative -replace '/', '\')
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::Copy($source, $destination, $false)
        if ((Get-CgceSha256 $source) -cne (Get-CgceSha256 $destination)) {
            throw "CGCE-TEST relocated handoff payload checksum mismatch"
        }
    }

    $destinationManifest = Join-Path `
        $destinationRoot `
        "source-manifest.sha256"
    [System.IO.File]::Copy(
        $Fixture.SourceManifestPath,
        $destinationManifest,
        $false
    )
    if ((Get-CgceSha256 $destinationManifest) -cne
            $Fixture.SourceManifestSha) {
        throw "CGCE-TEST relocated handoff manifest checksum mismatch"
    }

    $Fixture.HandoffRoot = $destinationRoot
    $Fixture.SourceManifestPath = $destinationManifest
    $Fixture.PrepareScript = Join-Path `
        $destinationRoot `
        "tools\windows-discovery\Prepare-CgceDiscovery.ps1"
    $Fixture.InvokeScript = Join-Path `
        $destinationRoot `
        "tools\windows-discovery\Invoke-CgceDiscovery.ps1"
    $Fixture.RestoreScript = Join-Path `
        $destinationRoot `
        "tools\windows-discovery\Restore-CgceProduction.ps1"
    $Fixture.ExportScript = Join-Path `
        $destinationRoot `
        "tools\windows-discovery\Export-CgceDiscoveryEvidence.ps1"
    $Fixture.FakeServerScript = Join-Path `
        $destinationRoot `
        "tests\windows\fixtures\FakePalServer.cmd"
    return $destinationRoot
}

function Assert-CgcePreparePreGenesisBlocked(
    $Fixture,
    [string]$ExpectedCode
) {
    $result = Invoke-CgcePrepareChild $Fixture
    Assert-CgceEqual $true ($result.ExitCode -ne 0)
    Assert-CgceEqual 1 @($result.Stdout).Count
    Assert-CgceEqual `
        "CGCE_WINDOWS_DISCOVERY_BLOCKED $ExpectedCode $($Fixture.RunId)" `
        $result.Stdout[0]
    Assert-CgceEqual "" $result.Stderr
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.state)
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.genesis_state)
    Assert-CgceEqual $false (Test-Path -LiteralPath $Fixture.Paths.inactive_original)
    Compare-CgceInventory `
        -Expected $Fixture.OriginalInventory `
        -Actual @(Get-CgceTreeInventory -Root $Fixture.Paths.active_saved)
}

function New-CgcePersistenceFaultSetup(
    $Fixture,
    [bool]$FailAfterBackupState,
    [bool]$FailBlockedPersistence
) {
    $template = @'
& $contractModule {
    param(
        [string]$serverRoot,
        [string]$lockEvidence,
        [bool]$failAfterBackupState,
        [bool]$failBlockedPersistence
    )
    $stateFaultFired = $false
    $script:CgceTestStatePersistenceSeam = {
        param([string]$phase, $context)
        if ($failAfterBackupState -and -not $stateFaultFired -and
            $phase -ceq "after-state-replace" -and
            $context.candidate.phase -ceq "BACKUP_VERIFIED" -and
            $context.candidate.outcome -ceq "ACTIVE") {
            $stateFaultFired = $true
            throw "CGCE-OPS-CHECKSUM injected state read-back fault"
        }
        if ($phase -ceq "before-state-replace" -and
            $context.candidate.outcome -ceq "BLOCKED") {
            $contended = $false
            try {
                $otherLock = Enter-CgceExclusiveLock `
                    -ServerRoot $serverRoot `
                    -RunId $context.candidate.run_id
                $otherLock.Dispose()
            } catch {
                $contended = $true
            }
            if (-not $contended) {
                throw "CGCE-TEST Prepare lock was not held during blocking"
            }
            [System.IO.File]::WriteAllText(
                $lockEvidence,
                "held",
                (New-Object System.Text.UTF8Encoding($false))
            )
            if ($failBlockedPersistence) {
                throw "CGCE-OPS-CHECKSUM injected blocked persistence fault"
            }
        }
    }.GetNewClosure()
} __SERVER_ROOT__ __LOCK_EVIDENCE__ __FAIL_STATE__ __FAIL_BLOCK__
'@
    $result = $template.Replace(
        "__SERVER_ROOT__",
        (ConvertTo-CgceLifecycleSingleQuoted $Fixture.ServerRoot)
    )
    $result = $result.Replace(
        "__LOCK_EVIDENCE__",
        (ConvertTo-CgceLifecycleSingleQuoted (
            Join-Path $Fixture.Base "lock-held.txt"
        ))
    )
    $result = $result.Replace(
        "__FAIL_STATE__",
        $(if ($FailAfterBackupState) { '$true' } else { '$false' })
    )
    $result = $result.Replace(
        "__FAIL_BLOCK__",
        $(if ($FailBlockedPersistence) { '$true' } else { '$false' })
    )
    return $result
}

function New-CgceFileFaultSetup(
    [string]$Kind,
    [string]$Target,
    [string]$MutationPath = ""
) {
    $template = @'
& $filesModule {
    param([string]$kind, [string]$target, [string]$mutationPath)
    $script:CgceTestPublishSeam = {
        param([string]$phase, $context)
        if ($kind -ceq "tree-before" -and
            $phase -ceq "tree-before-publish" -and
            $context.destination -ceq $target) {
            throw "CGCE-OPS-COPY injected tree publication fault"
        }
        if ($kind -ceq "move-before" -and
            $phase -ceq "move-before-publish" -and
            $context.destination -ceq $target) {
            throw "CGCE-OPS-COPY injected rename fault"
        }
        if ($kind -ceq "tree-after-mutate" -and
            $phase -ceq "tree-after-publish" -and
            $context.destination -ceq $target) {
            [System.IO.File]::AppendAllText(
                $mutationPath,
                "drift",
                (New-Object System.Text.UTF8Encoding($false))
            )
        }
    }.GetNewClosure()
} __KIND__ __TARGET__ __MUTATION__
'@
    $result = $template.Replace(
        "__KIND__",
        (ConvertTo-CgceLifecycleSingleQuoted $Kind)
    )
    $result = $result.Replace(
        "__TARGET__",
        (ConvertTo-CgceLifecycleSingleQuoted $Target)
    )
    $result = $result.Replace(
        "__MUTATION__",
        (ConvertTo-CgceLifecycleSingleQuoted $MutationPath)
    )
    return $result
}

function New-CgceProbeFaultSetup {
    return @'
& $runtimeModule {
    $script:CgceTestProbeCrashSeam = {
        param([string]$point)
        if ($point -ceq "before-receipt-999") {
            throw "CGCE-OPS-PROBE-RECEIPT injected final receipt fault"
        }
    }
}
'@
}

function New-CgceActivityDriftSetup(
    $Fixture,
    [ValidateSet("process", "listener")]
    [string]$Kind
) {
    $template = @'
& $runtimeModule {
    param(
        [string]$kind,
        [string]$serverExecutable,
        [int]$listenerPort
    )
    $calls = 0
    $script:CgceTestActivitySnapshotSeam = {
        $calls += 1
        $processes = [object[]]@()
        $tcp = [object[]]@()
        if ($calls -ge 2 -and $kind -ceq "process") {
            $processes = [object[]]@(
                [pscustomobject]@{
                    ProcessId = 4242
                    ExecutablePath = $serverExecutable
                }
            )
        }
        if ($calls -ge 2 -and $kind -ceq "listener") {
            $tcp = [object[]]@(
                [pscustomobject]@{
                    LocalPort = $listenerPort
                    State = "Listen"
                }
            )
        }
        return [pscustomobject]@{
            cim_available = $true
            tcp_available = $true
            udp_available = $true
            processes = $processes
            tcp = $tcp
            udp = [object[]]@()
        }
    }.GetNewClosure()
} __KIND__ __SERVER_EXECUTABLE__ __LISTENER_PORT__
'@
    $result = $template.Replace(
        "__KIND__",
        (ConvertTo-CgceLifecycleSingleQuoted $Kind)
    )
    $result = $result.Replace(
        "__SERVER_EXECUTABLE__",
        (ConvertTo-CgceLifecycleSingleQuoted $Fixture.ServerExecutable)
    )
    $result = $result.Replace(
        "__LISTENER_PORT__",
        $Fixture.ControlListenerPort.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
    )
    return $result
}

function New-CgceInvokeLaunchDriftSetup(
    [ValidateSet("probe-residue", "ue4ss-drift")]
    [string]$Kind,
    [string]$Target
) {
    $template = @'
& $runtimeModule {
    param([string]$kind, [string]$target)
    $script:CgceTestLaunchReceiptSeam = {
        param([string]$Path)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        if ($kind -ceq "probe-residue") {
            [System.IO.File]::WriteAllText(
                $target,
                "synthetic late probe output",
                $encoding
            )
        } else {
            [System.IO.File]::AppendAllText(
                $target,
                "synthetic drift",
                $encoding
            )
        }
    }.GetNewClosure()
} __KIND__ __TARGET__
'@
    $result = $template.Replace(
        "__KIND__",
        (ConvertTo-CgceLifecycleSingleQuoted $Kind)
    )
    $result = $result.Replace(
        "__TARGET__",
        (ConvertTo-CgceLifecycleSingleQuoted $Target)
    )
    return $result
}

function New-CgceInvokeProcessCrashSetup([string]$CrashPoint) {
    $template = @'
& $runtimeModule {
    param([string]$crashPoint)
    $script:CgceTestProcessCrashSeam = {
        param([string]$point)
        if ($point -ceq $crashPoint) {
            throw "CGCE-OPS-PROCESS-QUERY synthetic process crash boundary"
        }
    }.GetNewClosure()
} __CRASH_POINT__
'@
    return $template.Replace(
        "__CRASH_POINT__",
        (ConvertTo-CgceLifecycleSingleQuoted $CrashPoint)
    )
}

Invoke-CgceTest "prepare pre-genesis failure matrix preserves active Saved bytes" {
    $cases = @(
        [pscustomobject]@{
            Name = "CLI/control path mismatch"
            Code = "CGCE-OPS-PATH"
            Setup = {
                param($Fixture)
                $otherServer = Join-Path $Fixture.Base "other-server"
                New-Item -ItemType Directory -Path $otherServer | Out-Null
                $Fixture.ServerRoot = $otherServer
            }
        },
        [pscustomobject]@{
            Name = "control checksum drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $text = [System.IO.File]::ReadAllText($Fixture.ControlPath)
                Write-CgceLifecycleUtf8 $Fixture.ControlPath ($text + " ")
            }
        },
        [pscustomobject]@{
            Name = "handoff manifest drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $text = [System.IO.File]::ReadAllText(
                    $Fixture.SourceManifestPath
                )
                Write-CgceLifecycleUtf8 `
                    $Fixture.SourceManifestPath `
                    ($text + ("f" * 64) + "  extra.txt`n")
            }
        },
        [pscustomobject]@{
            Name = "handoff payload drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                $readme = Join-Path `
                    $Fixture.HandoffRoot `
                    "tools\windows-discovery\README.md"
                Write-CgceLifecycleUtf8 $readme "tampered handoff payload"
            }
        },
        [pscustomobject]@{
            Name = "UE4SS checksum drift"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    (Join-Path $Fixture.Ue4ssRoot "UE4SS.dll") `
                    "tampered synthetic UE4SS"
            }
        },
        [pscustomobject]@{
            Name = "unsupported UE4SS"
            Code = "CGCE-OPS-CONTROL"
            Setup = {
                param($Fixture)
                Update-CgceLifecycleControl $Fixture {
                    param($Control, $Ignored)
                    $Control.ue4ss_version = "3.0.2"
                }
            }
        },
        [pscustomobject]@{
            Name = "incomplete server process path attestation"
            Code = "CGCE-OPS-CONTROL"
            Setup = {
                param($Fixture)
                Update-CgceLifecycleControl $Fixture {
                    param($Control, $Ignored)
                    $Control.server_process_paths_complete = $false
                }
            }
        },
        [pscustomobject]@{
            Name = "expired control evidence"
            Code = "CGCE-OPS-CONTROL-EXPIRED"
            Setup = {
                param($Fixture)
                Update-CgceLifecycleControl $Fixture {
                    param($Control, $Ignored)
                    $Control.verified_at_utc = "2020-01-01T00:00:00Z"
                    $Control.valid_until_utc = "2020-01-01T01:00:00Z"
                }
            }
        },
        [pscustomobject]@{
            Name = "Saved containment escape"
            Code = "CGCE-OPS-PATH"
            Setup = {
                param($Fixture)
                $escaped = Join-Path $Fixture.Base "outside\Saved"
                New-Item -ItemType Directory -Path $escaped -Force | Out-Null
                $Fixture.SavedPath = $escaped
            }
        },
        [pscustomobject]@{
            Name = "foreign active marker"
            Code = "CGCE-OPS-FOREIGN-ARTIFACT"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    $Fixture.Paths.active_run_marker `
                    "{}"
            }
        },
        [pscustomobject]@{
            Name = "foreign inactive original"
            Code = "CGCE-OPS-FOREIGN-ARTIFACT"
            Setup = {
                param($Fixture)
                $foreign = $Fixture.Paths.active_saved +
                    ".cgce-original-r-ffffffffffffffffffffffffffffffff"
                New-Item -ItemType Directory -Path $foreign | Out-Null
            }
        },
        [pscustomobject]@{
            Name = "existing inventory probe"
            Code = "CGCE-OPS-PROBE-EXISTS"
            Setup = {
                param($Fixture)
                New-Item `
                    -ItemType Directory `
                    -Path $Fixture.Paths.probe_staged |
                    Out-Null
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $null = & $case.Setup $fixture
            Assert-CgcePreparePreGenesisBlocked `
                -Fixture $fixture `
                -ExpectedCode $case.Code
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare post-genesis fault matrix blocks under the held lock" {
    $cases = @(
        [pscustomobject]@{
            Name = "backup publication"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "backup"
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.backup_saved
            }
        },
        [pscustomobject]@{
            Name = "state replace/read-back"
            Code = "CGCE-OPS-BACKUP"
            Phase = "BACKUP_VERIFIED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $true
            FailBlock = $false
            Fault = { param($Fixture) "" }
        },
        [pscustomobject]@{
            Name = "original rename"
            Code = "CGCE-OPS-COPY"
            Phase = "BACKUP_VERIFIED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "move-before" `
                    -Target $Fixture.Paths.inactive_original
            }
        },
        [pscustomobject]@{
            Name = "clone publication"
            Code = "CGCE-OPS-CLONE"
            Phase = "ORIGINAL_DEACTIVATED"
            OriginalLocation = "inactive"
            ActiveExpected = $false
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $true
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "active"
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.active_saved
            }
        },
        [pscustomobject]@{
            Name = "probe final receipt"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Phase = "CLONE_ACTIVE"
            OriginalLocation = "inactive"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $true
            InactiveExpected = $true
            CloneRecorded = $true
            ProbePrefixExpected = $true
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = { param($Fixture) New-CgceProbeFaultSetup }
        },
        [pscustomobject]@{
            Name = "blocked-state persistence"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = "backup"
            FailState = $false
            FailBlock = $true
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-before" `
                    -Target $Fixture.Paths.backup_saved
            }
        },
        [pscustomobject]@{
            Name = "PalServer drift"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-after-mutate" `
                    -Target $Fixture.Paths.backup_saved `
                    -MutationPath $Fixture.ServerExecutable
            }
        },
        [pscustomobject]@{
            Name = "UE4SS drift"
            Code = "CGCE-OPS-BACKUP"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $true
            BackupInventoryDisk = $true
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceFileFaultSetup `
                    -Kind "tree-after-mutate" `
                    -Target $Fixture.Paths.backup_saved `
                    -MutationPath $Fixture.Paths.ue4ss_dll
            }
        },
        [pscustomobject]@{
            Name = "process drift"
            Code = "CGCE-OPS-PROCESS-ACTIVE"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceActivityDriftSetup `
                    -Fixture $Fixture `
                    -Kind "process"
            }
        },
        [pscustomobject]@{
            Name = "listener drift"
            Code = "CGCE-OPS-PORT-ACTIVE"
            Phase = "CREATED"
            OriginalLocation = "active"
            ActiveExpected = $true
            BackupDisk = $false
            BackupInventoryDisk = $false
            BackupRecorded = $false
            InactiveExpected = $false
            CloneRecorded = $false
            ProbePrefixExpected = $false
            StagingTarget = ""
            FailState = $false
            FailBlock = $false
            Fault = {
                param($Fixture)
                New-CgceActivityDriftSetup `
                    -Fixture $Fixture `
                    -Kind "listener"
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $moduleSetup = (& $case.Fault $fixture) + "`r`n" +
                (New-CgcePersistenceFaultSetup `
                    -Fixture $fixture `
                    -FailAfterBackupState $case.FailState `
                    -FailBlockedPersistence $case.FailBlock)
            $result = Invoke-CgcePrepareChild `
                -Fixture $fixture `
                -ModuleSetup $moduleSetup
            Assert-CgceEqual $true ($result.ExitCode -ne 0)
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED $($case.Code) $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceEqual `
                $true `
                (Test-Path -LiteralPath (
                    Join-Path $fixture.Base "lock-held.txt"
                ) -PathType Leaf)
            $state = Read-CgceRunState `
                -RunRoot $fixture.RunRoot `
                -RunId $fixture.RunId
            Assert-CgceEqual $case.Phase $state.phase
            Assert-CgceEqual `
                $(if ($case.FailBlock) { "ACTIVE" } else { "BLOCKED" }) `
                $state.outcome
            if (-not $case.FailBlock) {
                Assert-CgceEqual $case.Code $state.errors[-1].code
            }
            Assert-CgceEqual `
                $case.ActiveExpected `
                (Test-Path -LiteralPath $fixture.Paths.active_saved -PathType Container)
            Assert-CgceEqual `
                $case.InactiveExpected `
                (Test-Path `
                    -LiteralPath $fixture.Paths.inactive_original `
                    -PathType Container)
            Assert-CgceEqual `
                $case.BackupDisk `
                (Test-Path `
                    -LiteralPath $fixture.Paths.backup_saved `
                    -PathType Container)
            Assert-CgceEqual `
                $case.BackupInventoryDisk `
                (Test-Path `
                    -LiteralPath $fixture.Paths.backup_inventory `
                    -PathType Leaf)
            Assert-CgceEqual `
                $case.BackupRecorded `
                ($null -ne $state.inventory_checksums.backup)
            Assert-CgceEqual `
                $case.CloneRecorded `
                ($null -ne $state.inventory_checksums.clone)
            Assert-CgceEqual `
                $case.CloneRecorded `
                (Test-Path `
                    -LiteralPath $fixture.Paths.clone_inventory `
                    -PathType Leaf)
            Assert-CgceEqual `
                $false `
                ($null -ne $state.probe_receipt_checksum)
            Assert-CgceEqual `
                $false `
                (Test-Path `
                    -LiteralPath $fixture.Paths.probe_receipt `
                    -PathType Leaf)
            $probePrefixCount = if (Test-Path `
                    -LiteralPath $fixture.Paths.probe_receipts `
                    -PathType Container) {
                @(Get-ChildItem `
                    -LiteralPath $fixture.Paths.probe_receipts `
                    -Force).Count
            } else {
                0
            }
            Assert-CgceEqual `
                $case.ProbePrefixExpected `
                ($probePrefixCount -gt 0)
            if ($case.BackupDisk) {
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.backup_saved)
            }
            if ($case.CloneRecorded) {
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.active_saved)
            }
            if (-not [string]::IsNullOrWhiteSpace($case.StagingTarget)) {
                $stagingDestination = if ($case.StagingTarget -ceq "backup") {
                    $fixture.Paths.backup_saved
                } else {
                    $fixture.Paths.active_saved
                }
                $stagingParent = Split-Path -Parent $stagingDestination
                $stagingLeaf = Split-Path -Leaf $stagingDestination
                $stagingEvidence = @(Get-ChildItem `
                        -LiteralPath $stagingParent `
                        -Filter ".$stagingLeaf.cgce-stage-tree-*" `
                        -Directory `
                        -Force)
                Assert-CgceEqual 1 $stagingEvidence.Count
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $stagingEvidence[0].FullName)
            }
            $originalPath = if ($case.OriginalLocation -ceq "active") {
                $fixture.Paths.active_saved
            } else {
                $fixture.Paths.inactive_original
            }
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory -Root $originalPath)
            Assert-CgceEqual `
                $fixture.SourceManifestSha `
                (Get-CgceSha256 $fixture.SourceManifestPath)
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare rejects a script executed outside the bound handoff tree with one line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.PrepareScript = $fixture.RepositoryPrepareScript
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.genesis_state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects a preloaded module from a different canonical path" {
    $fixture = New-CgceSyntheticFixture
    try {
        $wrongRoot = Join-Path $fixture.Base "wrong-origin"
        New-Item -ItemType Directory -Path $wrongRoot | Out-Null
        $wrongContract = Join-Path `
            $wrongRoot `
            "CgceDiscovery.Contract.psm1"
        [System.IO.File]::Copy(
            (Join-Path `
                $fixture.HandoffRoot `
                "tools\windows-discovery\modules\CgceDiscovery.Contract.psm1"),
            $wrongContract,
            $false
        )
        $moduleSetup = '$wrongContractModule = Import-Module ' +
            (ConvertTo-CgceLifecycleSingleQuoted $wrongContract) +
            ' -Global -Force -PassThru'
        $result = Invoke-CgcePrepareChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.genesis_state)
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare keeps one terminal line when catch-path inspection throws" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fileFault = New-CgceFileFaultSetup `
            -Kind "tree-before" `
            -Target $fixture.Paths.backup_saved
        $testPathFault = @'
$global:CgceThrowStatePathProbe = $false
& $filesModule {
    $prior = $script:CgceTestPublishSeam
    $script:CgceTestPublishSeam = {
        param([string]$phase, $context)
        try {
            $null = & $prior $phase $context
        } catch {
            $global:CgceThrowStatePathProbe = $true
            throw
        }
    }.GetNewClosure()
}
function global:Test-Path {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,
        [Microsoft.PowerShell.Commands.TestPathType]$PathType =
            [Microsoft.PowerShell.Commands.TestPathType]::Any
    )
    if ($global:CgceThrowStatePathProbe -and
        $LiteralPath.EndsWith(
            "run-state.json",
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "CGCE-TEST injected catch Test-Path fault"
    }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
'@
        $result = Invoke-CgcePrepareChild `
            -Fixture $fixture `
            -ModuleSetup ($fileFault + "`r`n" + $testPathFault)
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-BACKUP $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "CREATED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare keeps one blocked line when lock disposal throws" {
    $fixture = New-CgceSyntheticFixture
    try {
        $moduleSetup = @'
$global:CgceRealEnterLock = Get-Command `
    -Name "Enter-CgceExclusiveLock" `
    -CommandType Function
function global:Enter-CgceExclusiveLock {
    param([string]$ServerRoot, [string]$RunId)
    $inner = & $global:CgceRealEnterLock `
        -ServerRoot $ServerRoot `
        -RunId $RunId
    $fake = [pscustomobject]@{ Inner = $inner }
    $fake | Add-Member `
        -MemberType ScriptMethod `
        -Name "Dispose" `
        -Value {
            $this.Inner.Dispose()
            throw "CGCE-TEST injected Dispose fault"
        }
    return $fake
}
'@
        $result = Invoke-CgcePrepareChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-LOCK $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "PROBE_STAGED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects exact executable leaf reparse points before genesis" {
    $cases = @(
        [pscustomobject]@{
            Name = "PalServer executable"
            SelectPath = { param($Fixture) $Fixture.ServerExecutable }
        },
        [pscustomobject]@{
            Name = "UE4SS DLL"
            SelectPath = { param($Fixture) $Fixture.Paths.ue4ss_dll }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceSyntheticFixture
        try {
            $leaf = & $case.SelectPath $fixture
            $target = Join-Path `
                $fixture.Base `
                ("same-bytes-" + [guid]::NewGuid().ToString("N"))
            [System.IO.File]::Copy($leaf, $target, $false)
            Remove-Item -LiteralPath $leaf -Force
            New-Item `
                -ItemType SymbolicLink `
                -Path $leaf `
                -Target $target |
                Out-Null
            Assert-CgcePreparePreGenesisBlocked `
                -Fixture $fixture `
                -ExpectedCode "CGCE-OPS-REPARSE"
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare preserves original and activates an equal clone with one terminal line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual 0 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_OK PROBE_STAGED $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
        Assert-CgceEqual "PROBE_STAGED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.inactive_original)
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.SavedPath)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.backup_saved)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.probe_receipt)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Assert-CgceEqual `
            $fixture.SourceManifestSha `
            (Get-CgceSha256 $fixture.SourceManifestPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects handoff and run-root overlap before genesis or production mutation" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.RunRoot = $fixture.HandoffRoot
        $fixture.Paths = New-CgceRunPaths `
            -ServerRoot $fixture.ServerRoot -SavedPath $fixture.SavedPath `
            -Ue4ssRoot $fixture.Ue4ssRoot -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PATH-OVERLAP $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.genesis_state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare renders a CRLF-bearing invalid run id as one safe terminal line" {
    $fixture = New-CgceSyntheticFixture
    try {
        $fixture.RunId = "bad`r`ninjected"
        $result = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-ID INVALID_RUN_ID" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "prepare rejects valid run-id prefixes with final line endings" {
    foreach ($suffix in @("`n", "`r`n")) {
        $fixture = New-CgceSyntheticFixture
        try {
            $fixture.RunId += $suffix
            $result = Invoke-CgcePrepareChild $fixture
            Assert-CgceEqual $true ($result.ExitCode -ne 0)
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-ID INVALID_RUN_ID" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceEqual $false (Test-Path -LiteralPath $fixture.Paths.state)
            Assert-CgceEqual `
                $false `
                (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "prepare replay rejects the existing final run directory without another mutation" {
    $fixture = New-CgceSyntheticFixture
    try {
        $first = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual 0 $first.ExitCode
        $activeBefore = @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        $inactiveBefore = @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)

        $second = Invoke-CgcePrepareChild $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual 1 @($second.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-STATE-EXISTS $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Compare-CgceInventory `
            -Expected $activeBefore `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Compare-CgceInventory `
            -Expected $inactiveBefore `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke runs a relocated prepared child once and captures only exact dump outputs" {
    $fixture = New-CgcePreparedFixture
    try {
        $preparedHandoffRoot = $fixture.HandoffRoot
        $relocatedHandoffRoot = Relocate-CgceLifecycleHandoff $fixture
        Assert-CgceEqual $false ($preparedHandoffRoot -ceq $relocatedHandoffRoot)
        Assert-CgceEqual `
            $fixture.SourceManifestSha `
            (Get-CgceSha256 $fixture.SourceManifestPath)
        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual 0 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_OK CAPTURED $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "CAPTURED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        foreach ($checksum in @(
            $state.process_launch_receipt_checksum,
            $state.process_result_receipt_checksum,
            $state.capture_inventory_checksum
        )) {
            Assert-CgceEqual $true ($checksum -cmatch '^[0-9a-f]{64}\z')
        }
        Assert-CgceEqual `
            $state.process_launch_receipt_checksum `
            (Get-CgceSha256 $state.paths.process_launch_receipt)
        Assert-CgceEqual `
            $state.process_result_receipt_checksum `
            (Get-CgceSha256 $state.paths.process_result_receipt)
        Assert-CgceEqual `
            $state.capture_inventory_checksum `
            (Get-CgceSha256 $state.paths.capture_inventory)

        $captureChildren = @(
            Get-ChildItem -LiteralPath $state.paths.capture -Force |
                ForEach-Object { $_.Name }
        )
        [Array]::Sort($captureChildren, [StringComparer]::Ordinal)
        Assert-CgceDeepEqual `
            @("CXXHeaderDump", "UE4SS_ObjectDump.txt") `
            $captureChildren
        Assert-CgceEqual `
            $true `
            ((Get-Item `
                -LiteralPath (Join-Path `
                    $state.paths.capture `
                    "UE4SS_ObjectDump.txt")).Length -gt 0)
        Assert-CgceEqual `
            $true `
            (@(Get-ChildItem `
                    -LiteralPath (Join-Path `
                        $state.paths.capture `
                        "CXXHeaderDump") `
                    -File `
                    -Recurse).Count -gt 0)

        $receiptNames = @(
            Get-ChildItem -LiteralPath $state.paths.process_receipts -Force |
                ForEach-Object { $_.Name }
        )
        [Array]::Sort($receiptNames, [StringComparer]::Ordinal)
        Assert-CgceDeepEqual `
            @("000-launch.json", "001-pid.json", "999-result.json") `
            $receiptNames
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.backup_saved)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke tracks an allowlisted child and grandchild to one final result" {
    $fixture = New-CgcePreparedFixture `
        -Mode "grandchild" `
        -IncludeSleeperInAllowlist $true `
        -IncludeLauncherInAllowlist $true
    try {
        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual 0 $result.ExitCode
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_OK CAPTURED $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        $rootReceipt = Read-CgceJsonObject `
            -Path (Join-Path $state.paths.process_receipts "001-pid.json")
        $childReceipt = Read-CgceJsonObject `
            -Path (Join-Path $state.paths.process_receipts "002-pid.json")
        $grandchildReceipt = Read-CgceJsonObject `
            -Path (Join-Path $state.paths.process_receipts "003-pid.json")
        Assert-CgceEqual 0 $rootReceipt.parent_pid
        Assert-CgceEqual $rootReceipt.pid $childReceipt.parent_pid
        Assert-CgceEqual $childReceipt.pid $grandchildReceipt.parent_pid
        Assert-CgceEqualCanonicalPath `
            -Expected $fixture.ServerExecutable `
            -Actual $rootReceipt.executable_path
        Assert-CgceEqualCanonicalPath `
            -Expected $fixture.RuntimeLauncher `
            -Actual $childReceipt.executable_path
        Assert-CgceEqualCanonicalPath `
            -Expected $fixture.RuntimeSleeper `
            -Actual $grandchildReceipt.executable_path

        $processResult = Read-CgceJsonObject `
            -Path $state.paths.process_result_receipt
        Assert-CgceEqual 3 @($processResult.pid_receipts).Count
        Assert-CgceEqual 3 @($processResult.observed_processes).Count
        Assert-CgceDeepEqual `
            @(
                "000-launch.json",
                "001-pid.json",
                "002-pid.json",
                "003-pid.json",
                "999-result.json"
            ) `
            @(
                Get-ChildItem `
                    -LiteralPath $state.paths.process_receipts `
                    -Force |
                    Sort-Object -Property Name |
                    ForEach-Object { $_.Name }
            )
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke waits for a detached listening descendant before capture" {
    $fixture = New-CgcePreparedFixture `
        -Mode "detached-listener" `
        -IncludeSleeperInAllowlist $true `
        -IncludeListenerInAllowlist $true
    try {
        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual 0 $result.ExitCode
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_OK CAPTURED $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual `
            $true `
            (Test-Path `
                -LiteralPath (Join-Path `
                    $fixture.ServerRoot `
                    "cgce-listener-exited.txt") `
                -PathType Leaf)

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        $processResult = Read-CgceJsonObject `
            -Path $state.paths.process_result_receipt
        $listenerProcesses = @(
            @($processResult.observed_processes) |
                Where-Object {
                    try {
                        Assert-CgceEqualCanonicalPath `
                            -Expected $fixture.RuntimeListener `
                            -Actual $_.executable_path
                        $true
                    } catch {
                        $false
                    }
                }
        )
        Assert-CgceEqual 1 $listenerProcesses.Count
        Assert-CgceNoServerActivity `
            -ExecutablePaths ([string[]]$state.server_process_paths) `
            -Ports ([int[]]$state.listener_ports) `
            -ReceiptRoot $state.paths.process_receipts
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke bounds genesis and manifest reads before module import" {
    $cases = @(
        [pscustomobject]@{
            Name = "oversized genesis"
            Target = { param($Fixture) $Fixture.Paths.genesis_state }
            RebindGenesis = $false
        },
        [pscustomobject]@{
            Name = "oversized source manifest"
            Target = { param($Fixture) $Fixture.SourceManifestPath }
            RebindGenesis = $true
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgcePreparedFixture
        try {
            $stateChecksum = Get-CgceSha256 $fixture.Paths.state
            $oversized = New-Object byte[] 1048577
            [System.IO.File]::WriteAllBytes(
                (& $case.Target $fixture),
                $oversized
            )
            if ($case.RebindGenesis) {
                $genesis = Read-CgceJsonObject `
                    -Path $fixture.Paths.genesis_state
                $genesis.source_manifest_checksum = Get-CgceSha256 `
                    $fixture.SourceManifestPath
                Write-CgceLifecycleUtf8 `
                    -Path $fixture.Paths.genesis_state `
                    -Text ($genesis | ConvertTo-Json -Depth 20)
            }

            $result = Invoke-CgceInvokeChild -Fixture $fixture
            Assert-CgceEqual $true ($result.ExitCode -ne 0)
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceEqual `
                $stateChecksum `
                (Get-CgceSha256 $fixture.Paths.state)
            Assert-CgceEqual `
                0 `
                @(Get-ChildItem `
                    -LiteralPath $fixture.Paths.process_receipts `
                    -Force).Count
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory `
                    -Root $fixture.Paths.inactive_original)
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "invoke rejects a re-signed handoff before importing its changed module" {
    $fixture = New-CgcePreparedFixture
    try {
        $sentinel = Join-Path $fixture.Base "drifted-module-loaded.txt"
        $contract = Join-Path `
            $fixture.HandoffRoot `
            "tools\windows-discovery\modules\CgceDiscovery.Contract.psm1"
        $text = [System.IO.File]::ReadAllText($contract)
        $sideEffect = '[System.IO.File]::WriteAllText(' +
            (ConvertTo-CgceLifecycleSingleQuoted $sentinel) +
            ", 'loaded')"
        Write-CgceLifecycleUtf8 `
            -Path $contract `
            -Text ($text + "`r`n" + $sideEffect + "`r`n")
        Update-CgceLifecycleHandoffManifest -Fixture $fixture

        $stateBefore = Get-CgceSha256 $fixture.Paths.state
        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $sentinel)
        Assert-CgceEqual $stateBefore (Get-CgceSha256 $fixture.Paths.state)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $fixture.Paths.process_receipts `
                -Force).Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke rejects plain handoff payload drift before process evidence" {
    $fixture = New-CgcePreparedFixture
    try {
        $runtime = Join-Path `
            $fixture.HandoffRoot `
            "tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1"
        $text = [System.IO.File]::ReadAllText($runtime)
        Write-CgceLifecycleUtf8 `
            -Path $runtime `
            -Text ($text + "`r`n# synthetic payload drift`r`n")
        $stateBefore = Get-CgceSha256 $fixture.Paths.state

        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $stateBefore (Get-CgceSha256 $fixture.Paths.state)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $fixture.Paths.process_receipts `
                -Force).Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke rejects handoff and run-root overlap before import" {
    $fixture = New-CgcePreparedFixture
    try {
        $preparedRunRoot = $fixture.RunRoot
        $stateBefore = Get-CgceSha256 $fixture.Paths.state
        $fixture.RunRoot = $fixture.HandoffRoot

        $result = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($result.ExitCode -ne 0)
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PATH-OVERLAP $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual `
            $stateBefore `
            (Get-CgceSha256 `
                (Join-Path `
                    (Join-Path $preparedRunRoot $fixture.RunId) `
                    "run-state.json"))
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $fixture.Paths.process_receipts `
                -Force).Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke failures block once without touching the inactive original" {
    $cases = @(
        [pscustomobject]@{
            Name = "secret argument"
            Mode = "success"
            Code = "CGCE-OPS-ARGUMENT"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path $Fixture.ArgumentsPath `
                    -Text '["-publiclobby"]'
            }
            ExpectedPhase = "PROBE_STAGED"
        },
        [pscustomobject]@{
            Name = "non-array argument JSON"
            Mode = "success"
            Code = "CGCE-OPS-JSON"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path $Fixture.ArgumentsPath `
                    -Text '{"argument":"not-an-array"}'
            }
            ExpectedPhase = "PROBE_STAGED"
        },
        [pscustomobject]@{
            Name = "PalServer checksum drift"
            Mode = "success"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path $Fixture.ServerExecutable `
                    -Text "drifted-executable"
            }
            ExpectedPhase = "PROBE_STAGED"
        },
        [pscustomobject]@{
            Name = "PalServer executable path drift"
            Mode = "success"
            Code = "CGCE-OPS-PATH"
            Setup = {
                param($Fixture)
                $otherExecutable = Join-Path `
                    $Fixture.ServerRoot `
                    "OtherPalServer.exe"
                [System.IO.File]::Copy(
                    $Fixture.ServerExecutable,
                    $otherExecutable,
                    $false
                )
                $Fixture.ServerExecutable = $otherExecutable
            }
            ExpectedPhase = "PROBE_STAGED"
        },
        [pscustomobject]@{
            Name = "UE4SS checksum drift"
            Mode = "success"
            Code = "CGCE-OPS-CHECKSUM"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path $Fixture.Paths.ue4ss_dll `
                    -Text "drifted-ue4ss"
            }
            ExpectedPhase = "PROBE_STAGED"
        },
        [pscustomobject]@{
            Name = "nonzero exit"
            Mode = "nonzero"
            Code = "CGCE-OPS-PROCESS-EXIT"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "empty object"
            Mode = "empty-object"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "missing object"
            Mode = "missing-object"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "missing header"
            Mode = "missing-header"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "missing completion"
            Mode = "missing-completion"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "duplicate completion"
            Mode = "duplicate-completion"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "blocked probe log"
            Mode = "blocked"
            Code = "CGCE-OPS-CAPTURE-MISSING"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
        },
        [pscustomobject]@{
            Name = "bounded timeout"
            Mode = "timeout"
            Code = "CGCE-OPS-PROCESS-TIMEOUT"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
            IncludeSleeper = $true
            TimeoutSeconds = 1
            WaitForInactive = $true
        },
        [pscustomobject]@{
            Name = "observed unlisted child"
            Mode = "unlisted-child"
            Code = "CGCE-OPS-PROCESS-UNLISTED"
            Setup = { param($Ignored) }
            ExpectedPhase = "RUNNING"
            WaitForInactive = $true
        }
    )
    foreach ($case in $cases) {
        $includeSleeper = (
            $null -ne $case.PSObject.Properties["IncludeSleeper"] -and
            [bool]$case.IncludeSleeper
        )
        $timeout = if (
            $null -ne $case.PSObject.Properties["TimeoutSeconds"]
        ) {
            [int]$case.TimeoutSeconds
        } else {
            30
        }
        $fixture = New-CgcePreparedFixture `
            -Mode $case.Mode `
            -IncludeSleeperInAllowlist $includeSleeper
        try {
            $null = & $case.Setup $fixture
            $result = Invoke-CgceInvokeChild `
                -Fixture $fixture `
                -TimeoutSeconds $timeout
            if (
                $null -ne $case.PSObject.Properties["WaitForInactive"] -and
                [bool]$case.WaitForInactive
            ) {
                Wait-CgceLifecycleServerInactive -Fixture $fixture
            }
            Assert-CgceEqual $true ($result.ExitCode -ne 0)
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED $($case.Code) $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            $state = Read-CgceRunState `
                -RunRoot $fixture.RunRoot `
                -RunId $fixture.RunId
            Assert-CgceEqual $case.ExpectedPhase $state.phase
            Assert-CgceEqual "BLOCKED" $state.outcome
            Assert-CgceEqual $case.Code $state.errors[-1].code
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory `
                    -Root $state.paths.inactive_original)
            Assert-CgceEqual `
                0 `
                @(Get-ChildItem `
                    -LiteralPath $state.paths.capture `
                    -Force).Count
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "invoke replay never launches a second child or rewrites evidence" {
    $fixture = New-CgcePreparedFixture
    try {
        $first = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual 0 $first.ExitCode
        $stateChecksum = Get-CgceSha256 $fixture.Paths.state
        $launchChecksum = Get-CgceSha256 `
            $fixture.Paths.process_launch_receipt
        $resultChecksum = Get-CgceSha256 `
            $fixture.Paths.process_result_receipt
        $capture = @(Get-CgceTreeInventory -Root $fixture.Paths.capture)

        $second = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual 1 @($second.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Assert-CgceEqual $stateChecksum (Get-CgceSha256 $fixture.Paths.state)
        Assert-CgceEqual `
            $launchChecksum `
            (Get-CgceSha256 $fixture.Paths.process_launch_receipt)
        Assert-CgceEqual `
            $resultChecksum `
            (Get-CgceSha256 $fixture.Paths.process_result_receipt)
        Compare-CgceInventory `
            -Expected $capture `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.capture)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke RUNNING failure is a one-launch replay barrier" {
    $fixture = New-CgcePreparedFixture
    try {
        $moduleSetup = @'
function global:Invoke-CgceChildProcess {
    throw "CGCE-OPS-PROCESS-QUERY synthetic pre-launch failure"
}
'@
        $first = Invoke-CgceInvokeChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Assert-CgceEqual $true ($first.ExitCode -ne 0)
        Assert-CgceEqual 1 @($first.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PROCESS-QUERY $($fixture.RunId)" `
            $first.Stdout[0]
        Assert-CgceEqual "" $first.Stderr
        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "RUNNING" $state.phase
        Assert-CgceEqual "BLOCKED" $state.outcome
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $state.paths.process_receipts `
                -Force).Count
        $stateChecksum = Get-CgceSha256 $state.paths.state

        $second = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Assert-CgceEqual $stateChecksum (Get-CgceSha256 $state.paths.state)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $state.paths.process_receipts `
                -Force).Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke launch intent is a durable no-relaunch crash barrier" {
    $fixture = New-CgcePreparedFixture
    try {
        $moduleSetup = @'
& $runtimeModule {
    $script:CgceTestLaunchReceiptSeam = {
        param([string]$Path)
        throw "CGCE-OPS-PROCESS-RECEIPT synthetic crash after launch intent"
    }
}
'@
        $first = Invoke-CgceInvokeChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Assert-CgceEqual $true ($first.ExitCode -ne 0)
        Assert-CgceEqual 1 @($first.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PROCESS-RECEIPT $($fixture.RunId)" `
            $first.Stdout[0]
        Assert-CgceEqual "" $first.Stderr

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "RUNNING" $state.phase
        Assert-CgceEqual "BLOCKED" $state.outcome
        $receiptNames = @(
            Get-ChildItem -LiteralPath $state.paths.process_receipts -Force |
                ForEach-Object { $_.Name }
        )
        Assert-CgceDeepEqual @("000-launch.json") $receiptNames
        $launchChecksum = Get-CgceSha256 `
            $state.paths.process_launch_receipt
        $stateChecksum = Get-CgceSha256 $state.paths.state

        $second = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual 1 @($second.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Assert-CgceEqual $stateChecksum (Get-CgceSha256 $state.paths.state)
        Assert-CgceEqual `
            $launchChecksum `
            (Get-CgceSha256 $state.paths.process_launch_receipt)
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath $state.paths.process_result_receipt)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $state.paths.capture `
                -Force).Count
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke pre-launch callback blocks late authority drift before PID evidence" {
    $cases = @(
        [pscustomobject]@{
            Name = "probe staged matrix drift"
            Kind = "probe-residue"
            Code = "CGCE-OPS-PROBE-RECEIPT"
            Target = { param($Fixture) $Fixture.Paths.object_dump }
        },
        [pscustomobject]@{
            Name = "UE4SS executable authority drift"
            Kind = "ue4ss-drift"
            Code = "CGCE-OPS-CHECKSUM"
            Target = { param($Fixture) $Fixture.Paths.ue4ss_dll }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgcePreparedFixture
        try {
            $target = & $case.Target $fixture
            $moduleSetup = New-CgceInvokeLaunchDriftSetup `
                -Kind $case.Kind `
                -Target $target
            $first = Invoke-CgceInvokeChild `
                -Fixture $fixture `
                -ModuleSetup $moduleSetup
            Assert-CgceEqual $true ($first.ExitCode -ne 0)
            Assert-CgceEqual 1 @($first.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED $($case.Code) $($fixture.RunId)" `
                $first.Stdout[0]
            Assert-CgceEqual "" $first.Stderr

            $state = Read-CgceRunState `
                -RunRoot $fixture.RunRoot `
                -RunId $fixture.RunId
            Assert-CgceEqual "RUNNING" $state.phase
            Assert-CgceEqual "BLOCKED" $state.outcome
            Assert-CgceDeepEqual `
                @("000-launch.json") `
                @(
                    Get-ChildItem `
                        -LiteralPath $state.paths.process_receipts `
                        -Force |
                        ForEach-Object { $_.Name }
                )
            Assert-CgceEqual `
                $false `
                (Test-Path -LiteralPath $state.paths.process_result_receipt)
            Assert-CgceEqual `
                0 `
                @(Get-ChildItem `
                    -LiteralPath $state.paths.capture `
                    -Force).Count

            $stateChecksum = Get-CgceSha256 $state.paths.state
            $launchChecksum = Get-CgceSha256 `
                $state.paths.process_launch_receipt
            $second = Invoke-CgceInvokeChild -Fixture $fixture
            Assert-CgceEqual $true ($second.ExitCode -ne 0)
            Assert-CgceEqual 1 @($second.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
                $second.Stdout[0]
            Assert-CgceEqual "" $second.Stderr
            Assert-CgceEqual `
                $stateChecksum `
                (Get-CgceSha256 $state.paths.state)
            Assert-CgceEqual `
                $launchChecksum `
                (Get-CgceSha256 $state.paths.process_launch_receipt)
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory `
                    -Root $state.paths.inactive_original)
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "invoke process crash boundaries preserve partial receipts and forbid relaunch" {
    $cases = @(
        [pscustomobject]@{
            Point = "after-process-start"
            PidCount = 0
        },
        [pscustomobject]@{
            Point = "after-pid-1"
            PidCount = 1
        },
        [pscustomobject]@{
            Point = "after-pid-2"
            PidCount = 2
        },
        [pscustomobject]@{
            Point = "after-pid-3"
            PidCount = 3
        },
        [pscustomobject]@{
            Point = "before-result"
            PidCount = 3
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgcePreparedFixture `
            -Mode "grandchild" `
            -IncludeSleeperInAllowlist $true `
            -IncludeLauncherInAllowlist $true
        try {
            $moduleSetup = New-CgceInvokeProcessCrashSetup `
                -CrashPoint $case.Point
            $first = Invoke-CgceInvokeChild `
                -Fixture $fixture `
                -ModuleSetup $moduleSetup
            Wait-CgceLifecycleServerInactive -Fixture $fixture
            Assert-CgceEqual $true ($first.ExitCode -ne 0)
            Assert-CgceEqual 1 @($first.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PROCESS-QUERY $($fixture.RunId)" `
                $first.Stdout[0]
            Assert-CgceEqual "" $first.Stderr

            $state = Read-CgceRunState `
                -RunRoot $fixture.RunRoot `
                -RunId $fixture.RunId
            Assert-CgceEqual "RUNNING" $state.phase
            Assert-CgceEqual "BLOCKED" $state.outcome
            $expectedReceiptNames = @("000-launch.json")
            for (
                $sequence = 1;
                $sequence -le $case.PidCount;
                $sequence += 1
            ) {
                $expectedReceiptNames += (
                    $sequence.ToString("000") + "-pid.json"
                )
            }
            $actualReceiptNames = @(
                Get-ChildItem `
                    -LiteralPath $state.paths.process_receipts `
                    -Force |
                    Sort-Object -Property Name |
                    ForEach-Object { $_.Name }
            )
            Assert-CgceDeepEqual `
                $expectedReceiptNames `
                $actualReceiptNames
            Assert-CgceEqual `
                $false `
                (Test-Path -LiteralPath $state.paths.process_result_receipt)

            $stateChecksum = Get-CgceSha256 $state.paths.state
            $receiptInventory = @(
                Get-CgceTreeInventory -Root $state.paths.process_receipts
            )
            $second = Invoke-CgceInvokeChild -Fixture $fixture
            Assert-CgceEqual $true ($second.ExitCode -ne 0)
            Assert-CgceEqual 1 @($second.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
                $second.Stdout[0]
            Assert-CgceEqual "" $second.Stderr
            Assert-CgceEqual `
                $stateChecksum `
                (Get-CgceSha256 $state.paths.state)
            Compare-CgceInventory `
                -Expected $receiptInventory `
                -Actual @(Get-CgceTreeInventory `
                    -Root $state.paths.process_receipts)
            Assert-CgceEqual `
                0 `
                @(Get-ChildItem `
                    -LiteralPath $state.paths.capture `
                    -Force).Count
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory `
                    -Root $state.paths.inactive_original)
        } catch {
            throw "CGCE-TEST $($case.Point): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

function New-CgceCapturedFixture {
    $fixture = New-CgcePreparedFixture
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name CapturedCloneInventory `
        -Value @(Get-CgceTreeInventory -Root $fixture.SavedPath)
    $captured = Invoke-CgceInvokeChild -Fixture $fixture
    if ($captured.ExitCode -ne 0 -or @($captured.Stdout).Count -ne 1 -or
        $captured.Stdout[0] -cne
            "CGCE_WINDOWS_DISCOVERY_OK CAPTURED $($fixture.RunId)" -or
        -not [string]::IsNullOrEmpty($captured.Stderr)) {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        throw "CGCE-TEST synthetic capture fixture failed"
    }
    $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
    Assert-CgceEqual "CAPTURED" $state.phase
    Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.inactive_original)
    return $fixture
}

function Invoke-CgceRestoreChild(
    $Fixture,
    [string]$ModuleSetup = ""
) {
    $stderrPath = Join-Path $Fixture.Base (
        "restore-stderr-" + [guid]::NewGuid().ToString("N")
    )
    $entryScript = $Fixture.RestoreScript
    if (-not [string]::IsNullOrWhiteSpace($ModuleSetup)) {
        $entryScript = Join-Path $Fixture.Base (
            "restore-wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1"
        )
        $toolRoot = Join-Path $Fixture.HandoffRoot "tools\windows-discovery"
        $wrapper = @(
            '$ErrorActionPreference = "Stop"'
            ('$commonModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "CgceDiscovery.Common.psm1"
                )) + ' -Global -PassThru')
            ('$contractModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Contract.psm1"
                )) + ' -Global -PassThru')
            ('$filesModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Files.psm1"
                )) + ' -Global -PassThru')
            ('$runtimeModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Runtime.psm1"
                )) + ' -Global -PassThru')
            $ModuleSetup
            ('& ' + (ConvertTo-CgceLifecycleSingleQuoted $Fixture.RestoreScript) +
                ' @args')
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        Write-CgceLifecycleUtf8 -Path $entryScript -Text ($wrapper + "`r`n")
    }
    $stdout = @(& "$PSHOME\powershell.exe" `
        -NoProfile -ExecutionPolicy Bypass -File $entryScript `
        -RunRoot $Fixture.RunRoot -RunId $Fixture.RunId 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($stderrPath)
    } else { "" }
    return [pscustomobject]@{
        ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr
    }
}

function Get-CgceLifecycleRestoreSnapshot($Fixture) {
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $Fixture.Base `
            -Directory -Force -Recurse | Sort-Object -Property FullName)) {
        $relativePath = $directory.FullName.Substring($Fixture.Base.Length)
        $values.Add("D|$($relativePath.TrimStart('\', '/'))")
    }
    foreach ($entry in @(Get-CgceTreeInventory -Root $Fixture.Base | Where-Object {
        $_.relative_path -cnotmatch '^(?:restore-stderr-|restore-wrapper-)'
    } | ForEach-Object {
        "F|$($_.relative_path)|$($_.length)|$($_.sha256)"
    })) { $values.Add($entry) }
    return [string[]]$values.ToArray()
}

function Assert-CgceRestoreTerminal(
    $Result,
    [int]$ExitCode,
    [string]$Line
) {
    Assert-CgceEqual $ExitCode $Result.ExitCode
    Assert-CgceEqual 1 @($Result.Stdout).Count
    Assert-CgceEqual $Line $Result.Stdout[0]
    Assert-CgceEqual "" $Result.Stderr
}

function Assert-CgceRestoredFixture($Fixture) {
    $state = Read-CgceRunState -RunRoot $Fixture.RunRoot -RunId $Fixture.RunId
    Assert-CgceEqual "RESTORED" $state.phase
    Assert-CgceEqual "ACTIVE" $state.outcome
    Assert-CgceEqual 0 @($state.errors).Count
    Assert-CgceEqual $true (Test-Path -LiteralPath $Fixture.SavedPath)
    Assert-CgceEqual $false (Test-Path -LiteralPath $state.paths.inactive_original)
    Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.quarantined_clone)
    Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.backup_saved)
    Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.completed_run_marker)
    Assert-CgceEqual $false (Test-Path -LiteralPath $state.paths.active_run_marker)
    Assert-CgceRunMarker -State $state -AllowCompleted
    Assert-CgceEqual $state.inventory_checksums.restored `
        (Get-CgceSha256 $state.paths.restored_inventory)
    Assert-CgceDeepEqual @(
        "000-restore-intent.json", "010-quarantine-clone.json",
        "020-restore-original.json", "999-restore-final.json"
    ) @(Get-ChildItem -LiteralPath $state.paths.restore_receipts -Force |
        Sort-Object -Property Name | ForEach-Object { $_.Name })
    Compare-CgceInventory -Expected $Fixture.OriginalInventory `
        -Actual @(Get-CgceTreeInventory -Root $Fixture.SavedPath)
    Compare-CgceInventory -Expected $Fixture.CapturedCloneInventory `
        -Actual @(Get-CgceTreeInventory -Root $state.paths.quarantined_clone)
    Compare-CgceInventory -Expected $Fixture.OriginalInventory `
        -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
    $restored = Read-CgceInventory -Path $state.paths.restored_inventory `
        -ExpectedKind "restored"
    Compare-CgceInventory -Expected $Fixture.OriginalInventory `
        -Actual @($restored.entries)
    Assert-CgceEqual 0 @(Assert-CgceInventoryProbeRestored `
        -Paths $state.paths -RunDirectory $state.paths.run_directory `
        -RunId $Fixture.RunId `
        -ExpectedFinalReceiptChecksum $state.probe_receipt_checksum).Count
}

Invoke-CgceTest "restore bootstrap rejects oversized genesis and manifest before import" {
    foreach ($case in @(
        [pscustomobject]@{ Name = "genesis"; Rebind = $false },
        [pscustomobject]@{ Name = "manifest"; Rebind = $true }
    )) {
        $fixture = New-CgceCapturedFixture
        try {
            $sentinel = Join-Path $fixture.Base (
                "bootstrap-imported-" + [guid]::NewGuid().ToString("N")
            )
            $runtime = Join-Path $fixture.HandoffRoot `
                "tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1"
            Write-CgceLifecycleUtf8 -Path $runtime -Text (
                ([System.IO.File]::ReadAllText($runtime)) + "`r`n" +
                ('[System.IO.File]::WriteAllText(' +
                    (ConvertTo-CgceLifecycleSingleQuoted $sentinel) + ", 'loaded')")
            )
            $target = if ($case.Name -ceq "genesis") {
                $fixture.Paths.genesis_state
            } else { $fixture.SourceManifestPath }
            [System.IO.File]::WriteAllBytes($target, (New-Object byte[] 1048577))
            if ($case.Rebind) {
                $genesis = Read-CgceJsonObject $fixture.Paths.genesis_state
                $genesis.source_manifest_checksum = Get-CgceSha256 $target
                Write-CgceLifecycleUtf8 `
                    -Path $fixture.Paths.genesis_state `
                    -Text ($genesis | ConvertTo-Json -Depth 20)
            }
            $authorityBefore = Get-CgceLifecycleRestoreSnapshot $fixture
            $result = Invoke-CgceRestoreChild -Fixture $fixture
            Assert-CgceEqual 1 $result.ExitCode
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceEqual $false (Test-Path -LiteralPath $sentinel)
            Assert-CgceDeepEqual $authorityBefore `
                (Get-CgceLifecycleRestoreSnapshot $fixture)
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "restore bootstrap rejects a wrong-origin preloaded handoff module" {
    $fixture = New-CgceCapturedFixture
    try {
        $before = Get-CgceLifecycleRestoreSnapshot $fixture
        $setup = 'Import-Module ' +
            (ConvertTo-CgceLifecycleSingleQuoted `
                (Join-Path (Split-Path -Parent $fixture.RepositoryInvokeScript) `
                    "modules\CgceDiscovery.Runtime.psm1")) +
            ' -Global -Force'
        $result = Invoke-CgceRestoreChild -Fixture $fixture -ModuleSetup $setup
        Assert-CgceEqual 1 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceDeepEqual $before (Get-CgceLifecycleRestoreSnapshot $fixture)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore bootstrap accepts relocated byte-identical handoff" {
    $fixture = New-CgceCapturedFixture
    try {
        $null = Relocate-CgceLifecycleHandoff $fixture
        $result = Invoke-CgceRestoreChild -Fixture $fixture
        Assert-CgceRestoreTerminal `
            -Result $result -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        Assert-CgceRestoredFixture $fixture
        $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
        Assert-CgceEqual "RESTORED" $state.phase
        Assert-CgceEqual $state.inventory_checksums.restored `
            (Get-CgceSha256 $state.paths.restored_inventory)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Compare-CgceInventory `
            -Expected $fixture.CapturedCloneInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.quarantined_clone)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
        $restoredInventory = Read-CgceInventory `
            -Path $state.paths.restored_inventory -ExpectedKind "restored"
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @($restoredInventory.entries)
        Assert-CgceEqual $true `
            (Test-Path -LiteralPath $state.paths.completed_run_marker)
        Assert-CgceEqual 0 @(Assert-CgceInventoryProbeRestored `
            -Paths $state.paths -RunDirectory $state.paths.run_directory `
            -RunId $fixture.RunId `
            -ExpectedFinalReceiptChecksum $state.probe_receipt_checksum).Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore bootstrap rejects either-direction handoff RunRoot overlap" {
    foreach ($direction in @("run-under-handoff", "handoff-under-run")) {
        $fixture = New-CgceCapturedFixture
        try {
            $authorityBefore = Get-CgceLifecycleRestoreSnapshot $fixture
            if ($direction -ceq "run-under-handoff") {
                $fixture.RunRoot = $fixture.HandoffRoot
            } else {
                $fixture.RunRoot = $fixture.Base
            }
            $result = Invoke-CgceRestoreChild -Fixture $fixture
            Assert-CgceEqual 1 $result.ExitCode
            Assert-CgceEqual 1 @($result.Stdout).Count
            Assert-CgceEqual `
                "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PATH-OVERLAP $($fixture.RunId)" `
                $result.Stdout[0]
            Assert-CgceEqual "" $result.Stderr
            Assert-CgceDeepEqual $authorityBefore `
                (Get-CgceLifecycleRestoreSnapshot $fixture)
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "restore bootstrap rejects a re-signed module tree with no side effect" {
    $fixture = New-CgceCapturedFixture
    try {
        $sentinel = Join-Path $fixture.Base "restore-module-side-effect.txt"
        $contract = Join-Path $fixture.HandoffRoot `
            "tools\windows-discovery\modules\CgceDiscovery.Contract.psm1"
        Write-CgceLifecycleUtf8 -Path $contract -Text (
            ([System.IO.File]::ReadAllText($contract)) + "`r`n" +
            ('[System.IO.File]::WriteAllText(' +
                (ConvertTo-CgceLifecycleSingleQuoted $sentinel) + ", 'loaded')")
        )
        Update-CgceLifecycleHandoffManifest $fixture
        $before = Get-CgceLifecycleRestoreSnapshot $fixture
        $result = Invoke-CgceRestoreChild -Fixture $fixture
        Assert-CgceEqual 1 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceEqual $false (Test-Path -LiteralPath $sentinel)
        Assert-CgceDeepEqual $before (Get-CgceLifecycleRestoreSnapshot $fixture)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore returns the exact original and quarantines the clone" {
    $fixture = New-CgceCapturedFixture
    try {
        $result = Invoke-CgceRestoreChild -Fixture $fixture
        Assert-CgceRestoreTerminal `
            -Result $result -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        Assert-CgceRestoredFixture $fixture
        $state = Read-CgceRunState -RunRoot $fixture.RunRoot -RunId $fixture.RunId
        Assert-CgceEqual "RESTORED" $state.phase
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.SavedPath)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.quarantined_clone)
        Assert-CgceEqual $false (Test-Path -LiteralPath $state.paths.inactive_original)
        Assert-CgceEqual "ACTIVE" $state.outcome
        Assert-CgceEqual 0 @($state.errors).Count
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.backup_saved)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.completed_run_marker)
        Assert-CgceEqual $false (Test-Path -LiteralPath $state.paths.active_run_marker)
        Assert-CgceEqual $true (Test-Path -LiteralPath $state.paths.restored_inventory)
        Assert-CgceEqual `
            $state.inventory_checksums.restored `
            (Get-CgceSha256 $state.paths.restored_inventory)
        Assert-CgceDeepEqual @(
            "000-restore-intent.json",
            "010-quarantine-clone.json",
            "020-restore-original.json",
            "999-restore-final.json"
        ) @(
            Get-ChildItem -LiteralPath $state.paths.restore_receipts -Force |
                Sort-Object -Property Name | ForEach-Object { $_.Name }
        )
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Compare-CgceInventory `
            -Expected $fixture.CapturedCloneInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.quarantined_clone)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $state.paths.backup_saved)
        $restoredInventory = Read-CgceInventory `
            -Path $state.paths.restored_inventory -ExpectedKind "restored"
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @($restoredInventory.entries)
        $probeOutput = @(Assert-CgceInventoryProbeRestored `
            -Paths $state.paths -RunDirectory $state.paths.run_directory `
            -RunId $fixture.RunId `
            -ExpectedFinalReceiptChecksum $state.probe_receipt_checksum)
        Assert-CgceEqual 0 $probeOutput.Count
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore resumes every intent operation inventory state and marker boundary" {
    $boundaries = @(
        [pscustomobject]@{ Point = "after-000-intent"; Phase = "CAPTURED"; Receipts = @("000-restore-intent.json"); Inactive = $true; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-RESTORING-CAS-before-010"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json"); Inactive = $true; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-010-move-before-receipt"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json"); Inactive = $true; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-010-receipt"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json"); Inactive = $true; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-020-move-before-receipt"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json"); Inactive = $false; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-020-receipt"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json", "020-restore-original.json"); Inactive = $false; Restored = $false; Completed = $false },
        [pscustomobject]@{ Point = "after-restored-inventory"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json", "020-restore-original.json"); Inactive = $false; Restored = $true; Completed = $false },
        [pscustomobject]@{ Point = "after-999"; Phase = "RESTORING"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json", "020-restore-original.json", "999-restore-final.json"); Inactive = $false; Restored = $true; Completed = $false },
        [pscustomobject]@{ Point = "after-RESTORED-state-before-marker"; Phase = "RESTORED"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json", "020-restore-original.json", "999-restore-final.json"); Inactive = $false; Restored = $true; Completed = $false },
        [pscustomobject]@{ Point = "after-completed-marker-before-terminal"; Phase = "RESTORED"; Receipts = @("000-restore-intent.json", "010-quarantine-clone.json", "020-restore-original.json", "999-restore-final.json"); Inactive = $false; Restored = $true; Completed = $true }
    )
    foreach ($boundary in $boundaries) {
        $fixture = New-CgceCapturedFixture
        try {
            $setupTemplate = @'
& $runtimeModule {
    param([string]$point)
    $script:CgceTestRestoreCrashSeam = {
        param([string]$actual)
        if ($actual -ceq $point) { [Environment]::Exit(197) }
    }.GetNewClosure()
} __POINT__
'@
            $setup = $setupTemplate.Replace(
                "__POINT__",
                (ConvertTo-CgceLifecycleSingleQuoted $boundary.Point)
            )
            $first = Invoke-CgceRestoreChild -Fixture $fixture -ModuleSetup $setup
            Assert-CgceEqual 197 $first.ExitCode
            Assert-CgceEqual 0 @($first.Stdout).Count
            Assert-CgceEqual "" $first.Stderr
            $current = Read-CgceRunState `
                -RunRoot $fixture.RunRoot -RunId $fixture.RunId
            Assert-CgceEqual $boundary.Phase $current.phase
            Assert-CgceEqual "ACTIVE" $current.outcome
            Assert-CgceEqual 0 @($current.errors).Count
            $expectedRevision = if ($boundary.Phase -ceq "CAPTURED") {
                6
            } elseif ($boundary.Phase -ceq "RESTORING") {
                7
            } else { 8 }
            Assert-CgceEqual $expectedRevision ([int64]$current.revision)
            Assert-CgceDeepEqual $boundary.Receipts @(
                Get-ChildItem -LiteralPath $fixture.Paths.restore_receipts -Force |
                    Sort-Object -Property Name | ForEach-Object { $_.Name }
            )
            Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.Paths.backup_saved)
            Assert-CgceEqual `
                $boundary.Inactive `
                (Test-Path -LiteralPath $fixture.Paths.inactive_original)
            if ($boundary.Inactive) {
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.inactive_original)
            }
            Assert-CgceEqual $boundary.Restored `
                (Test-Path -LiteralPath $fixture.Paths.restored_inventory)
            if ($boundary.Restored) {
                $restoredInventory = Read-CgceInventory `
                    -Path $fixture.Paths.restored_inventory `
                    -ExpectedKind "restored"
                Compare-CgceInventory `
                    -Expected $fixture.OriginalInventory `
                    -Actual @($restoredInventory.entries)
                $restoredChecksum = Get-CgceSha256 `
                    $fixture.Paths.restored_inventory
                if ($boundary.Phase -ceq "RESTORED") {
                    Assert-CgceEqual `
                        $restoredChecksum `
                        $current.inventory_checksums.restored
                } else {
                    Assert-CgceEqual $null $current.inventory_checksums.restored
                }
            }
            Assert-CgceEqual $boundary.Completed `
                (Test-Path -LiteralPath $fixture.Paths.completed_run_marker)
            Assert-CgceEqual (-not $boundary.Completed) `
                (Test-Path -LiteralPath $fixture.Paths.active_run_marker)
            if ($boundary.Completed) {
                Assert-CgceRunMarker -State $current -AllowCompleted
            } else {
                Assert-CgceRunMarker -State $current
            }
            $afterQuarantineMove = $boundary.Point -like "after-010-*" -or
                $boundary.Point -like "after-020-*" -or
                $boundary.Restored
            $activeExists = -not ($boundary.Point -like "after-010-*")
            Assert-CgceEqual $activeExists `
                (Test-Path -LiteralPath $fixture.SavedPath)
            Assert-CgceEqual $afterQuarantineMove `
                (Test-Path -LiteralPath $fixture.Paths.quarantined_clone)
            Compare-CgceInventory `
                -Expected $fixture.OriginalInventory `
                -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.backup_saved)
            if ($afterQuarantineMove) {
                Compare-CgceInventory `
                    -Expected $fixture.CapturedCloneInventory `
                    -Actual @(Get-CgceTreeInventory `
                        -Root $fixture.Paths.quarantined_clone)
            }
            if ($activeExists) {
                $activeExpected = if ($afterQuarantineMove) {
                    $fixture.OriginalInventory
                } else { $fixture.CapturedCloneInventory }
                Compare-CgceInventory `
                    -Expected $activeExpected `
                    -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
            }
            $second = Invoke-CgceRestoreChild -Fixture $fixture
            Assert-CgceRestoreTerminal `
                -Result $second -ExitCode 0 `
                -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
            Assert-CgceRestoredFixture $fixture
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "restore ambiguous quarantine layout fails closed without mutation" {
    $fixture = New-CgceCapturedFixture
    try {
        $null = Copy-CgceTreeVerified `
            -Source $fixture.SavedPath `
            -Destination $fixture.Paths.quarantined_clone
        $before = Get-CgceLifecycleRestoreSnapshot $fixture
        $result = Invoke-CgceRestoreChild -Fixture $fixture
        Assert-CgceRestoreTerminal `
            -Result $result -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-MANUAL-RECOVERY $($fixture.RunId)"
        Assert-CgceDeepEqual $before (Get-CgceLifecycleRestoreSnapshot $fixture)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.Paths.backup_saved)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "completed marker uses the read-only probe validator and performs no repair" {
    $fixture = New-CgceCapturedFixture
    try {
        Assert-CgceRestoreTerminal `
            -Result (Invoke-CgceRestoreChild -Fixture $fixture) -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        Move-Item -LiteralPath $fixture.Paths.probe_quarantine `
            -Destination $fixture.Paths.probe_staged
        $before = Get-CgceLifecycleRestoreSnapshot $fixture
        $result = Invoke-CgceRestoreChild -Fixture $fixture
        Assert-CgceEqual 1 $result.ExitCode
        Assert-CgceEqual 1 @($result.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-MANUAL-RECOVERY $($fixture.RunId)" `
            $result.Stdout[0]
        Assert-CgceEqual "" $result.Stderr
        Assert-CgceDeepEqual $before (Get-CgceLifecycleRestoreSnapshot $fixture)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "restore completed-marker replay emits one terminal line and writes nothing" {
    $fixture = New-CgceCapturedFixture
    try {
        Assert-CgceRestoreTerminal `
            -Result (Invoke-CgceRestoreChild -Fixture $fixture) -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        $before = Get-CgceLifecycleRestoreSnapshot $fixture
        Assert-CgceRestoreTerminal `
            -Result (Invoke-CgceRestoreChild -Fixture $fixture) -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        Assert-CgceDeepEqual $before (Get-CgceLifecycleRestoreSnapshot $fixture)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "invoke root PID receipt survives a post-creation crash without relaunch" {
    $fixture = New-CgcePreparedFixture
    try {
        $moduleSetup = @'
& $runtimeModule {
    $script:CgceTestRootProcessRecordSeam = {
        param($Process, [string]$CanonicalPath)
        throw "CGCE-OPS-PROCESS-QUERY synthetic crash after process creation"
    }
}
'@
        $first = Invoke-CgceInvokeChild `
            -Fixture $fixture `
            -ModuleSetup $moduleSetup
        Wait-CgceLifecycleServerInactive -Fixture $fixture
        Assert-CgceEqual $true ($first.ExitCode -ne 0)
        Assert-CgceEqual 1 @($first.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PROCESS-QUERY $($fixture.RunId)" `
            $first.Stdout[0]
        Assert-CgceEqual "" $first.Stderr

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "RUNNING" $state.phase
        Assert-CgceEqual "BLOCKED" $state.outcome
        $receiptNames = @(
            Get-ChildItem -LiteralPath $state.paths.process_receipts -Force |
                ForEach-Object { $_.Name }
        )
        [Array]::Sort($receiptNames, [StringComparer]::Ordinal)
        Assert-CgceDeepEqual `
            @("000-launch.json", "001-pid.json") `
            $receiptNames
        $launchChecksum = Get-CgceSha256 `
            $state.paths.process_launch_receipt
        $pidChecksum = Get-CgceSha256 `
            (Join-Path $state.paths.process_receipts "001-pid.json")
        $stateChecksum = Get-CgceSha256 $state.paths.state

        $second = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual $true ($second.ExitCode -ne 0)
        Assert-CgceEqual 1 @($second.Stdout).Count
        Assert-CgceEqual `
            "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PHASE $($fixture.RunId)" `
            $second.Stdout[0]
        Assert-CgceEqual "" $second.Stderr
        Assert-CgceEqual $stateChecksum (Get-CgceSha256 $state.paths.state)
        Assert-CgceEqual `
            $launchChecksum `
            (Get-CgceSha256 $state.paths.process_launch_receipt)
        Assert-CgceEqual `
            $pidChecksum `
            (Get-CgceSha256 `
                (Join-Path $state.paths.process_receipts "001-pid.json"))
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath $state.paths.process_result_receipt)
        Assert-CgceEqual `
            0 `
            @(Get-ChildItem `
                -LiteralPath $state.paths.capture `
                -Force).Count
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory `
                -Root $state.paths.inactive_original)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

function New-CgceRestoredFixture {
    $fixture = New-CgceCapturedFixture
    $restored = Invoke-CgceRestoreChild -Fixture $fixture
    Assert-CgceRestoreTerminal `
        -Result $restored `
        -ExitCode 0 `
        -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
    Assert-CgceRestoredFixture $fixture
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name ExportPath `
        -Value (Join-Path `
            $fixture.OutputRoot `
            "CGCE-Windows-Discovery-$($fixture.RunId).zip")
    $fixture | Add-Member `
        -MemberType NoteProperty `
        -Name ExportSidecarPath `
        -Value (Join-Path `
            $fixture.OutputRoot `
            "CGCE-Windows-Discovery-$($fixture.RunId).zip.sha256")
    return $fixture
}

function Invoke-CgceExportChild(
    $Fixture,
    [switch]$Resume,
    [string]$ModuleSetup = "",
    [string]$OutputDirectory = ""
) {
    $stderrPath = Join-Path $Fixture.Base (
        "export-stderr-" + [guid]::NewGuid().ToString("N")
    )
    $entryScript = $Fixture.ExportScript
    if (-not [string]::IsNullOrWhiteSpace($ModuleSetup)) {
        $entryScript = Join-Path $Fixture.Base (
            "export-wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1"
        )
        $toolRoot = Join-Path $Fixture.HandoffRoot "tools\windows-discovery"
        $wrapper = @(
            '$ErrorActionPreference = "Stop"'
            ('$commonModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "CgceDiscovery.Common.psm1"
                )) + ' -Global -PassThru')
            ('$contractModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Contract.psm1"
                )) + ' -Global -PassThru')
            ('$filesModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Files.psm1"
                )) + ' -Global -PassThru')
            ('$runtimeModule = Import-Module ' +
                (ConvertTo-CgceLifecycleSingleQuoted (
                    Join-Path $toolRoot "modules\CgceDiscovery.Runtime.psm1"
                )) + ' -Global -PassThru')
            $ModuleSetup
            ('& ' + (ConvertTo-CgceLifecycleSingleQuoted $Fixture.ExportScript) +
                ' @args')
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        Write-CgceLifecycleUtf8 -Path $entryScript -Text ($wrapper + "`r`n")
    }
    $boundOutputDirectory = if ([string]::IsNullOrWhiteSpace(
            $OutputDirectory
        )) {
        $Fixture.OutputRoot
    } else {
        $OutputDirectory
    }
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryScript,
        "-RunRoot", $Fixture.RunRoot,
        "-RunId", $Fixture.RunId,
        "-OutputDirectory", $boundOutputDirectory
    )
    if ($Resume) {
        $arguments += "-Resume"
    }
    $stdout = @(& "$PSHOME\powershell.exe" @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($stderrPath)
    } else {
        ""
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Assert-CgceExportTerminal(
    $Result,
    [int]$ExitCode,
    [string]$Line
) {
    Assert-CgceEqual $ExitCode $Result.ExitCode
    Assert-CgceEqual 1 @($Result.Stdout).Count
    Assert-CgceEqual $Line $Result.Stdout[0]
    Assert-CgceEqual "" $Result.Stderr
}

function Get-CgceLifecycleArchiveEntries([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return [string[]]@(
            $archive.Entries |
                ForEach-Object { $_.FullName } |
                Sort-Object
        )
    } finally {
        $archive.Dispose()
    }
}

function Read-CgceLifecycleArchiveText(
    [string]$Path,
    [string]$EntryName
) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) {
            throw "CGCE-TEST archive entry is missing"
        }
        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new(
                $stream,
                (New-Object System.Text.UTF8Encoding($false, $true)),
                $false
            )
            try {
                return $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function ConvertTo-CgceLifecycleUtf8Bytes([string]$Text) {
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    return ,$bytes
}

function Get-CgceLifecycleBytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Replace-CgceLifecycleArchiveText(
    [string]$Path,
    [string]$EntryName,
    [string]$Text
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open(
        $Path,
        [IO.Compression.ZipArchiveMode]::Update
    )
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) {
            throw "CGCE-TEST archive entry is missing"
        }
        $entry.Delete()
        $replacement = $archive.CreateEntry(
            $EntryName,
            [IO.Compression.CompressionLevel]::Optimal
        )
        $replacement.LastWriteTime = [DateTimeOffset]::new(
            1980, 1, 1, 0, 0, 0,
            [TimeSpan]::Zero
        )
        $bytes = ConvertTo-CgceLifecycleUtf8Bytes $Text
        $stream = $replacement.Open()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Write-CgceLifecycleArchiveSidecar(
    [string]$ArchivePath,
    [string]$SidecarPath
) {
    Write-CgceLifecycleUtf8 `
        -Path $SidecarPath `
        -Text ((Get-CgceSha256 $ArchivePath) + "  " +
            (Split-Path -Leaf $ArchivePath) + "`n")
}

function Write-CgceLifecycleAuthorityJson(
    [string]$Path,
    $Value
) {
    Write-CgceLifecycleUtf8 `
        -Path $Path `
        -Text ($Value | ConvertTo-Json -Depth 12)
}

function Update-CgceLifecycleGenesisAndState(
    $Fixture,
    [scriptblock]$Mutation
) {
    $genesis = Read-CgceJsonObject -Path $Fixture.Paths.genesis_state
    $state = Read-CgceJsonObject -Path $Fixture.Paths.state
    $null = & $Mutation $genesis $state $Fixture
    Write-CgceLifecycleAuthorityJson `
        -Path $Fixture.Paths.genesis_state `
        -Value $genesis
    Write-CgceLifecycleAuthorityJson `
        -Path $Fixture.Paths.state `
        -Value $state
    $markerPath = if (Test-Path `
            -LiteralPath $Fixture.Paths.completed_run_marker `
            -PathType Leaf) {
        $Fixture.Paths.completed_run_marker
    } else {
        $Fixture.Paths.active_run_marker
    }
    $marker = Read-CgceJsonObject -Path $markerPath
    $marker.genesis_state_checksum = Get-CgceSha256 `
        $Fixture.Paths.genesis_state
    Write-CgceLifecycleAuthorityJson -Path $markerPath -Value $marker
    $null = Read-CgceRunState `
        -RunRoot $Fixture.RunRoot `
        -RunId $Fixture.RunId
}

function Set-CgceLifecycleRestoredBlocked($Fixture) {
    $state = Read-CgceJsonObject -Path $Fixture.Paths.state
    $state.revision = [int64]$state.revision + 1
    $state.updated_at_utc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $state.outcome = "BLOCKED"
    $state.errors = [object[]]@(
        [pscustomobject][ordered]@{
            code = "CGCE-OPS-EXPORT-ALLOWLIST"
            at_utc = $state.updated_at_utc
        }
    )
    Write-CgceLifecycleAuthorityJson `
        -Path $Fixture.Paths.state `
        -Value $state
    $null = Read-CgceRunState `
        -RunRoot $Fixture.RunRoot `
        -RunId $Fixture.RunId
}

Invoke-CgceTest "export rejects non-restored and blocked runs without output" {
    $captured = New-CgceCapturedFixture
    try {
        $captured | Add-Member `
            -MemberType NoteProperty `
            -Name ExportPath `
            -Value (Join-Path `
                $captured.OutputRoot `
                "CGCE-Windows-Discovery-$($captured.RunId).zip")
        $before = Get-CgceSha256 $captured.Paths.state
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $captured) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-EXPORT-PHASE $($captured.RunId)"
        Assert-CgceEqual $before (Get-CgceSha256 $captured.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $captured.ExportPath)
    } finally {
        Remove-Item -LiteralPath $captured.Base -Recurse -Force
    }

    $blocked = New-CgceRestoredFixture
    try {
        Set-CgceLifecycleRestoredBlocked $blocked
        $before = Get-CgceSha256 $blocked.Paths.state
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $blocked) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-EXPORT-PHASE $($blocked.RunId)"
        Assert-CgceEqual $before (Get-CgceSha256 $blocked.Paths.state)
        Assert-CgceEqual $false (Test-Path -LiteralPath $blocked.ExportPath)
    } finally {
        Remove-Item -LiteralPath $blocked.Base -Recurse -Force
    }
}

Invoke-CgceTest "export rejects missing, escaped, sensitive, and existing output" {
    $cases = @(
        [pscustomobject]@{
            Name = "missing restored inventory"
            Code = "CGCE-OPS-EXPORT-ALLOWLIST"
            Setup = {
                param($Fixture)
                [IO.File]::Delete($Fixture.Paths.restored_inventory)
            }
        },
        [pscustomobject]@{
            Name = "escaped restored inventory path"
            Code = "CGCE-OPS-EXPORT-ALLOWLIST"
            Setup = {
                param($Fixture)
                $escaped = Join-Path `
                    $Fixture.Base `
                    "escaped-restored.json"
                [IO.File]::Copy(
                    $Fixture.Paths.restored_inventory,
                    $escaped,
                    $false
                )
                $mutation = {
                    param($Genesis, $State, $Ignored)
                    $Genesis.paths.restored_inventory = $escaped
                    $State.paths.restored_inventory = $escaped
                }.GetNewClosure()
                Update-CgceLifecycleGenesisAndState `
                    -Fixture $Fixture `
                    -Mutation $mutation
            }
        },
        [pscustomobject]@{
            Name = "sensitive capture extension"
            Code = "CGCE-OPS-EXPORT-SENSITIVE"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path (Join-Path `
                        $Fixture.Paths.capture `
                        "CXXHeaderDump\player.sav") `
                    -Text "synthetic sensitive bytes"
            }
        },
        [pscustomobject]@{
            Name = "structured secret field"
            Code = "CGCE-OPS-EXPORT-SENSITIVE"
            Setup = {
                param($Fixture)
                $control = Read-CgceJsonObject `
                    -Path $Fixture.Paths.control_evidence
                $control | Add-Member `
                    -MemberType NoteProperty `
                    -Name AdminPassword `
                    -Value "synthetic-secret"
                Write-CgceLifecycleAuthorityJson `
                    -Path $Fixture.Paths.control_evidence `
                    -Value $control
                $checksum = Get-CgceSha256 `
                    $Fixture.Paths.control_evidence
                $mutation = {
                    param($Genesis, $State, $Ignored)
                    $Genesis.control_evidence_checksum = $checksum
                    $State.control_evidence_checksum = $checksum
                }.GetNewClosure()
                Update-CgceLifecycleGenesisAndState `
                    -Fixture $Fixture `
                    -Mutation $mutation
            }
        },
        [pscustomobject]@{
            Name = "stale control evidence"
            Code = "CGCE-OPS-CONTROL-EXPIRED"
            Setup = {
                param($Fixture)
                $control = Read-CgceJsonObject `
                    -Path $Fixture.Paths.control_evidence
                $control.verified_at_utc = "2020-01-01T00:00:00Z"
                $control.valid_until_utc = "2020-01-01T01:00:00Z"
                Write-CgceLifecycleAuthorityJson `
                    -Path $Fixture.Paths.control_evidence `
                    -Value $control
                $checksum = Get-CgceSha256 `
                    $Fixture.Paths.control_evidence
                $mutation = {
                    param($Genesis, $State, $Ignored)
                    $Genesis.control_evidence_checksum = $checksum
                    $State.control_evidence_checksum = $checksum
                }.GetNewClosure()
                Update-CgceLifecycleGenesisAndState `
                    -Fixture $Fixture `
                    -Mutation $mutation
            }
        },
        [pscustomobject]@{
            Name = "existing output"
            Code = "CGCE-OPS-EXPORT-EXISTS"
            Setup = {
                param($Fixture)
                Write-CgceLifecycleUtf8 `
                    -Path $Fixture.ExportPath `
                    -Text "do-not-overwrite"
            }
        }
    )
    foreach ($case in $cases) {
        $fixture = New-CgceRestoredFixture
        try {
            $null = & $case.Setup $fixture
            $before = Get-CgceSha256 $fixture.Paths.state
            Assert-CgceExportTerminal `
                -Result (Invoke-CgceExportChild -Fixture $fixture) `
                -ExitCode 1 `
                -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED $($case.Code) $($fixture.RunId)"
            Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
            if ($case.Name -ceq "existing output") {
                Assert-CgceEqual `
                    "do-not-overwrite" `
                    ([IO.File]::ReadAllText($fixture.ExportPath))
            }
        } catch {
            throw "CGCE-TEST $($case.Name): $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $fixture.Base -Recurse -Force
        }
    }
}

Invoke-CgceTest "export rejects output overlap with handoff authority" {
    $fixture = New-CgceRestoredFixture
    try {
        $before = Get-CgceSha256 $fixture.Paths.state
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild `
                -Fixture $fixture `
                -OutputDirectory $fixture.HandoffRoot) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-PATH-OVERLAP $($fixture.RunId)"
        Assert-CgceEqual $before (Get-CgceSha256 $fixture.Paths.state)
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath (Join-Path `
                $fixture.HandoffRoot `
                "CGCE-Windows-Discovery-$($fixture.RunId).zip"))
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "export archives the exact private allowlist after restore" {
    $fixture = New-CgceRestoredFixture
    try {
        $restoredStateText = [IO.File]::ReadAllText($fixture.Paths.state)
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $fixture) `
            -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK EXPORTED $($fixture.RunId)"

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "EXPORTED" $state.phase
        Assert-CgceEqual "SUCCEEDED" $state.outcome
        Assert-CgceRunMarker -State $state -AllowCompleted
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.ExportPath)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $fixture.ExportSidecarPath)
        Assert-CgceDeepEqual @(
            "capture/CXXHeaderDump/Synthetic.hpp",
            "capture/UE4SS_ObjectDump.txt",
            "control-evidence.json",
            "export-manifest.json",
            "inventories/backup.json",
            "inventories/clone.json",
            "inventories/original.json",
            "inventories/restored.json",
            "run-state.json"
        ) @(Get-CgceLifecycleArchiveEntries $fixture.ExportPath)
        Assert-CgceEqual `
            $restoredStateText `
            (Read-CgceLifecycleArchiveText `
                -Path $fixture.ExportPath `
                -EntryName "run-state.json")
        $manifest = (
            Read-CgceLifecycleArchiveText `
                -Path $fixture.ExportPath `
                -EntryName "export-manifest.json"
        ) | ConvertFrom-Json
        Assert-CgceEqual `
            "cgce_windows_discovery_export_manifest" `
            $manifest.kind
        Assert-CgceEqual "PRIVATE" $manifest.privacy
        Assert-CgceEqual 8 @($manifest.payload).Count
        $sidecar = [IO.File]::ReadAllText($fixture.ExportSidecarPath)
        Assert-CgceEqual `
            ((Get-CgceSha256 $fixture.ExportPath) + "  " +
                (Split-Path -Leaf $fixture.ExportPath) + "`n") `
            $sidecar
        foreach ($entry in @(Get-CgceLifecycleArchiveEntries `
                $fixture.ExportPath)) {
            if ($entry -cmatch '(^|/)(Saved|Config)(/|$)' -or
                $entry -cmatch '(?i)\.(sav|ini|key|pem)\z' -or
                $entry -ceq "mods.txt") {
                throw "CGCE-TEST sensitive export entry found"
            }
        }
        Compare-CgceInventory `
            -Expected $fixture.OriginalInventory `
            -Actual @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $state.paths.backup_saved)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $state.paths.quarantined_clone)
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}

Invoke-CgceTest "export resume accepts only its exact verified archive" {
    $crashSetup = @'
& $contractModule {
    $script:CgceTestStatePersistenceSeam = {
        param([string]$phase, $context)
        if ($phase -ceq "before-state-replace" -and
            $context.candidate.phase -ceq "EXPORTED") {
            throw "CGCE-OPS-CHECKSUM synthetic export crash"
        }
    }
}
'@

    $resume = New-CgceRestoredFixture
    try {
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild `
                -Fixture $resume `
                -ModuleSetup $crashSetup) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($resume.RunId)"
        $state = Read-CgceRunState `
            -RunRoot $resume.RunRoot `
            -RunId $resume.RunId
        Assert-CgceEqual "RESTORED" $state.phase
        Assert-CgceEqual "ACTIVE" $state.outcome
        Assert-CgceEqual $true (Test-Path -LiteralPath $resume.ExportPath)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $resume.ExportSidecarPath)
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $resume -Resume) `
            -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK EXPORTED $($resume.RunId)"
        $state = Read-CgceRunState `
            -RunRoot $resume.RunRoot `
            -RunId $resume.RunId
        Assert-CgceEqual "EXPORTED" $state.phase
        Assert-CgceEqual "SUCCEEDED" $state.outcome
    } finally {
        Remove-Item -LiteralPath $resume.Base -Recurse -Force
    }

    $tampered = New-CgceRestoredFixture
    try {
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild `
                -Fixture $tampered `
                -ModuleSetup $crashSetup) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($tampered.RunId)"
        [IO.File]::AppendAllText(
            $tampered.ExportPath,
            "tamper",
            (New-Object Text.UTF8Encoding($false))
        )
        $before = Get-CgceSha256 $tampered.Paths.state
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $tampered -Resume) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($tampered.RunId)"
        Assert-CgceEqual $before (Get-CgceSha256 $tampered.Paths.state)
    } finally {
        Remove-Item -LiteralPath $tampered.Base -Recurse -Force
    }

    $rebound = New-CgceRestoredFixture
    try {
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild `
                -Fixture $rebound `
                -ModuleSetup $crashSetup) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($rebound.RunId)"
        $manifest = (
            Read-CgceLifecycleArchiveText `
                -Path $rebound.ExportPath `
                -EntryName "export-manifest.json"
        ) | ConvertFrom-Json
        $record = @($manifest.payload | Where-Object {
            $_.relative_path -ceq "control-evidence.json"
        })
        Assert-CgceEqual 1 $record.Count
        $replacementText = '{"tampered":true}'
        $replacementBytes = ConvertTo-CgceLifecycleUtf8Bytes `
            $replacementText
        $record[0].length = [int64]$replacementBytes.Length
        $record[0].sha256 = Get-CgceLifecycleBytesSha256 `
            $replacementBytes
        Replace-CgceLifecycleArchiveText `
            -Path $rebound.ExportPath `
            -EntryName "control-evidence.json" `
            -Text $replacementText
        Replace-CgceLifecycleArchiveText `
            -Path $rebound.ExportPath `
            -EntryName "export-manifest.json" `
            -Text ($manifest | ConvertTo-Json -Depth 12)
        Write-CgceLifecycleArchiveSidecar `
            -ArchivePath $rebound.ExportPath `
            -SidecarPath $rebound.ExportSidecarPath
        $before = Get-CgceSha256 $rebound.Paths.state
        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $rebound -Resume) `
            -ExitCode 1 `
            -Line "CGCE_WINDOWS_DISCOVERY_BLOCKED CGCE-OPS-CHECKSUM $($rebound.RunId)"
        Assert-CgceEqual $before (Get-CgceSha256 $rebound.Paths.state)
    } finally {
        Remove-Item -LiteralPath $rebound.Base -Recurse -Force
    }
}

Invoke-CgceTest "full synthetic lifecycle restores original bytes and exports evidence" {
    $fixture = New-CgcePreparedFixture
    try {
        $fixture | Add-Member `
            -MemberType NoteProperty `
            -Name CapturedCloneInventory `
            -Value @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        $fixture | Add-Member `
            -MemberType NoteProperty `
            -Name ExportPath `
            -Value (Join-Path `
                $fixture.OutputRoot `
                "CGCE-Windows-Discovery-$($fixture.RunId).zip")
        $fixture | Add-Member `
            -MemberType NoteProperty `
            -Name ExportSidecarPath `
            -Value "$($fixture.ExportPath).sha256"

        $before = @(Get-CgceTreeInventory -Root $fixture.Paths.inactive_original)
        $captured = Invoke-CgceInvokeChild -Fixture $fixture
        Assert-CgceEqual 0 $captured.ExitCode
        Assert-CgceDeepEqual `
            @("CGCE_WINDOWS_DISCOVERY_OK CAPTURED $($fixture.RunId)") `
            @($captured.Stdout)
        Assert-CgceEqual "" $captured.Stderr

        Assert-CgceRestoreTerminal `
            -Result (Invoke-CgceRestoreChild -Fixture $fixture) `
            -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK RESTORED $($fixture.RunId)"
        Assert-CgceRestoredFixture $fixture

        Assert-CgceExportTerminal `
            -Result (Invoke-CgceExportChild -Fixture $fixture) `
            -ExitCode 0 `
            -Line "CGCE_WINDOWS_DISCOVERY_OK EXPORTED $($fixture.RunId)"
        $after = @(Get-CgceTreeInventory -Root $fixture.SavedPath)
        Compare-CgceInventory -Expected $before -Actual $after

        $state = Read-CgceRunState `
            -RunRoot $fixture.RunRoot `
            -RunId $fixture.RunId
        Assert-CgceEqual "EXPORTED" $state.phase
        Assert-CgceEqual "SUCCEEDED" $state.outcome
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $state.paths.quarantined_clone)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $state.paths.backup_saved)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $state.paths.completed_run_marker)
        Assert-CgceEqual `
            $false `
            (Test-Path -LiteralPath $state.paths.active_run_marker)
        Assert-CgceEqual $true (Test-Path -LiteralPath $fixture.ExportPath)
        Assert-CgceEqual `
            $true `
            (Test-Path -LiteralPath $fixture.ExportSidecarPath)
        Assert-CgceEqual `
            (Get-CgceSha256 $fixture.ExportPath) `
            (([IO.File]::ReadAllText(
                $fixture.ExportSidecarPath
            ).Trim() -split '\s+')[0])
    } finally {
        Remove-Item -LiteralPath $fixture.Base -Recurse -Force
    }
}
