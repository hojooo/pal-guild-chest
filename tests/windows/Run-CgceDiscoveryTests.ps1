$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TestHarness.ps1")

$tests = @(
    "Contract.Tests.ps1",
    "Files.Tests.ps1",
    "Runtime.Tests.ps1",
    "Lifecycle.Tests.ps1"
)
foreach ($test in $tests) { . (Join-Path $PSScriptRoot $test) }
Write-Output "CGCE_WINDOWS_TESTS failures=$script:CgceFailures"
if ($script:CgceFailures -ne 0) { exit 1 }
exit 0
