$ErrorActionPreference = "Stop"

$script:CgceSelectedTestNames = @(
    "Windows PowerShell 5.1 smoke isolates unrelated production activity",
    "handoff manifest accepts only the exact sorted payload allowlist",
    "run-state replacement reopens new state while preserving the old file handle",
    "canonical paths preserve Windows volume roots and normalize descendants",
    "path component scan rejects a junction before the target",
    "verified tree copy returns an exact inventory and never overwrites",
    "recovery matrix resumes only intent-bound before or after states",
    "probe restored validator is read-only over absent and completed authorities",
    "export archives the exact private allowlist after restore",
    "full synthetic lifecycle restores original bytes and exports evidence"
)

$isDesktop51 = $PSVersionTable.PSEdition -ceq "Desktop" -and
    $PSVersionTable.PSVersion.Major -eq 5 -and
    $PSVersionTable.PSVersion.Minor -eq 1 -and
    $PSVersionTable.CLRVersion.Major -eq 4
if (-not $isDesktop51) {
    Write-Output "FAIL Windows PowerShell 5.1 Desktop with CLR 4 is required"
    Write-Output "CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=1"
    exit 1
}

. (Join-Path $PSScriptRoot "TestHarness.ps1")
foreach ($test in @(
        "Contract.Tests.ps1",
        "Files.Tests.ps1",
        "Runtime.Tests.ps1",
        "Lifecycle.Tests.ps1",
        "Smoke.Tests.ps1"
    )) {
    . (Join-Path $PSScriptRoot $test)
}
Complete-CgceTestSelection

$requestedCount = @($script:CgceSelectedTestNames).Count
if ($requestedCount -ne 10) {
    $script:CgceFailures += 1
    Write-Output "FAIL smoke runner must request exactly 10 tests"
}
Write-Output (
    "CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=" +
        $script:CgceFailures
)
if ($script:CgceFailures -ne 0 -or
    $script:CgceExecutedTestNames.Count -ne 10) {
    exit 1
}
exit 0
