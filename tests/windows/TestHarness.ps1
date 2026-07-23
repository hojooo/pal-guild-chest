$script:CgceFailures = 0
function Invoke-CgceTest([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Output "PASS $Name"
    } catch {
        $script:CgceFailures += 1
        Write-Output "FAIL $Name`n$($_.Exception.Message)"
    }
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
