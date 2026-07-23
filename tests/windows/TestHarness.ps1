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
function Assert-CgceThrows([string]$Code, [scriptblock]$Body) {
    try { & $Body } catch {
        if ($_.Exception.Message -like "$Code*") { return }
        throw "expected error $Code but got $($_.Exception.Message)"
    }
    throw "expected error $Code but no error was thrown"
}
