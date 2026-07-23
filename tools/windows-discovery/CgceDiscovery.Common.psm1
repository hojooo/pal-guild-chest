Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$contractModule = Join-Path $PSScriptRoot "modules\CgceDiscovery.Contract.psm1"
Import-Module $contractModule -Force -Scope Global | Out-Null
