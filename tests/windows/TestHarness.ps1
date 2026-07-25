$script:CgceFailures = 0
$script:CgceSelectionCompleted = $false
$script:CgceExecutedTestNames = New-Object `
    'System.Collections.Generic.HashSet[string]' `
    -ArgumentList ([StringComparer]::Ordinal)
$script:CgceRequestedTestNames = $null
$selectedVariable = Get-Variable `
    -Name "CgceSelectedTestNames" `
    -Scope Script `
    -ErrorAction SilentlyContinue
if ($null -ne $selectedVariable -and
    $null -ne $script:CgceSelectedTestNames) {
    $script:CgceRequestedTestNames = New-Object `
        'System.Collections.Generic.HashSet[string]' `
        -ArgumentList ([StringComparer]::Ordinal)
    foreach ($selectedName in @($script:CgceSelectedTestNames)) {
        if ($selectedName -isnot [string] -or
            [string]::IsNullOrWhiteSpace($selectedName)) {
            $script:CgceFailures += 1
            Write-Output "FAIL test selection contains an invalid name"
            continue
        }
        if (-not $script:CgceRequestedTestNames.Add($selectedName)) {
            $script:CgceFailures += 1
            Write-Output "FAIL test selection contains duplicate name $selectedName"
        }
    }
}

function Invoke-CgceTest([string]$Name, [scriptblock]$Body) {
    if ($null -ne $script:CgceRequestedTestNames -and
        -not $script:CgceRequestedTestNames.Contains($Name)) {
        return
    }
    if (-not $script:CgceExecutedTestNames.Add($Name)) {
        $script:CgceFailures += 1
        Write-Output "FAIL duplicate test definition $Name"
        return
    }
    try {
        & $Body
        Write-Output "PASS $Name"
    } catch {
        $script:CgceFailures += 1
        Write-Output "FAIL $Name`n$($_.Exception.Message)"
    }
}

function Complete-CgceTestSelection {
    if ($null -eq $script:CgceRequestedTestNames -or
        $script:CgceSelectionCompleted) {
        return
    }
    foreach ($selectedName in @($script:CgceSelectedTestNames)) {
        if ($selectedName -is [string] -and
            -not [string]::IsNullOrWhiteSpace($selectedName) -and
            -not $script:CgceExecutedTestNames.Contains($selectedName)) {
            $script:CgceFailures += 1
            Write-Output "FAIL selected test is missing $selectedName"
        }
    }
    $script:CgceSelectionCompleted = $true
}

function Assert-CgceEqual($Expected, $Actual) {
    if ($Expected -ne $Actual) {
        throw "expected=[$Expected] actual=[$Actual]"
    }
}
function Assert-CgceDeepEqual($Expected, $Actual) {
    $expectedIsArray = $Expected -is [System.Array]
    $actualIsArray = $Actual -is [System.Array]
    if ($expectedIsArray -or $actualIsArray) {
        if (-not $expectedIsArray -or -not $actualIsArray) {
            throw "expected and actual array shapes differ"
        }
        if ($Expected.Count -ne $Actual.Count) {
            throw "expected count=[$($Expected.Count)] actual count=[$($Actual.Count)]"
        }
        for ($index = 0; $index -lt $Expected.Count; $index += 1) {
            try {
                Assert-CgceDeepEqual `
                    -Expected $Expected[$index] `
                    -Actual $Actual[$index]
            } catch {
                throw "index=[$index] $($_.Exception.Message)"
            }
        }
        return
    }
    if ($null -eq $Expected -or $null -eq $Actual) {
        if ($null -ne $Expected -or $null -ne $Actual) {
            throw "expected=[$Expected] actual=[$Actual]"
        }
        return
    }
    if ($Expected -is [string] -and $Actual -is [string]) {
        if ($Expected -cne $Actual) {
            throw "expected=[$Expected] actual=[$Actual]"
        }
        return
    }
    if ($Expected -ne $Actual) {
        throw "expected=[$Expected] actual=[$Actual]"
    }
}
function Assert-CgceThrows([string]$Code, [scriptblock]$Body) {
    try { & $Body } catch {
        if ($_.Exception.Message -like "$Code*") { return }
        throw "expected error $Code but got $($_.Exception.Message)"
    }
    throw "expected error $Code but no error was thrown"
}
