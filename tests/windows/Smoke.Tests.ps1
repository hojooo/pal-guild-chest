Import-Module `
    "$PSScriptRoot\..\..\tools\windows-discovery\modules\CgceDiscovery.Runtime.psm1" `
    -Force

function Set-CgceSmokeActivitySnapshot($Snapshot) {
    $module = Get-Module "CgceDiscovery.Runtime"
    & $module {
        param($Value)
        $captured = $Value
        $script:CgceTestActivitySnapshotSeam = if ($null -eq $Value) {
            $null
        } else {
            { return $captured }.GetNewClosure()
        }
    } $Snapshot
}

function New-CgceSmokeActivitySnapshot(
    [object[]]$Processes,
    [object[]]$Tcp,
    [object[]]$Udp
) {
    return [pscustomobject]@{
        cim_available = $true
        tcp_available = $true
        udp_available = $true
        processes = [object[]]$Processes
        tcp = [object[]]$Tcp
        udp = [object[]]$Udp
    }
}

Invoke-CgceTest "Windows PowerShell 5.1 smoke isolates unrelated production activity" {
    Assert-CgceEqual "Desktop" $PSVersionTable.PSEdition
    Assert-CgceEqual 5 $PSVersionTable.PSVersion.Major
    Assert-CgceEqual 1 $PSVersionTable.PSVersion.Minor
    Assert-CgceEqual 4 $PSVersionTable.CLRVersion.Major

    $configuredPort = 48211
    $serverPath = "D:\CGCE-Smoke\PalServer.exe"
    try {
        Set-CgceSmokeActivitySnapshot (
            New-CgceSmokeActivitySnapshot `
                -Processes @([pscustomobject]@{
                    ProcessId = 73
                    ExecutablePath = "D:\Unrelated\Service.exe"
                }) `
                -Tcp @() `
                -Udp @([pscustomobject]@{ LocalPort = 8211 })
        )
        Assert-CgceNoServerActivity `
            -ExecutablePaths @($serverPath) `
            -Ports @($configuredPort)

        Set-CgceSmokeActivitySnapshot (
            New-CgceSmokeActivitySnapshot `
                -Processes @([pscustomobject]@{
                    ProcessId = 74
                    ExecutablePath = $serverPath
                }) `
                -Tcp @() `
                -Udp @()
        )
        Assert-CgceThrows "CGCE-OPS-PROCESS-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @($serverPath) `
                -Ports @($configuredPort)
        }

        Set-CgceSmokeActivitySnapshot (
            New-CgceSmokeActivitySnapshot `
                -Processes @() `
                -Tcp @() `
                -Udp @([pscustomobject]@{ LocalPort = $configuredPort })
        )
        Assert-CgceThrows "CGCE-OPS-PORT-ACTIVE" {
            Assert-CgceNoServerActivity `
                -ExecutablePaths @($serverPath) `
                -Ports @($configuredPort)
        }
    } finally {
        Set-CgceSmokeActivitySnapshot $null
    }
}

Invoke-CgceTest "test harness rejects duplicate and missing smoke selections" {
    $root = Join-Path `
        $env:TEMP `
        ("cgce-smoke-harness-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $childPath = Join-Path $root "verify-selection.ps1"
        $child = @'
param(
    [string]$HarnessPath,
    [ValidateSet("duplicate", "missing")]
    [string]$Mode
)
$ErrorActionPreference = "Stop"
$script:CgceSelectedTestNames = if ($Mode -ceq "duplicate") {
    @("alpha", "alpha")
} else {
    @("alpha", "beta")
}
. $HarnessPath
Invoke-CgceTest "alpha" {}
Complete-CgceTestSelection
if ($script:CgceFailures -ne 1 -or
    $script:CgceExecutedTestNames.Count -ne 1 -or
    -not $script:CgceSelectionCompleted) {
    exit 1
}
exit 0
'@
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($childPath, $child, $encoding)
        $harnessPath = Join-Path $PSScriptRoot "TestHarness.ps1"
        foreach ($mode in @("duplicate", "missing")) {
            $output = @(
                & "$PSHOME\powershell.exe" `
                    -NoProfile `
                    -ExecutionPolicy Bypass `
                    -File $childPath `
                    -HarnessPath $harnessPath `
                    -Mode $mode
            )
            Assert-CgceEqual 0 $LASTEXITCODE
            Assert-CgceEqual $true ($output.Count -ge 2)
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
