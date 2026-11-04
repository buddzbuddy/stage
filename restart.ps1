[CmdletBinding()]
param(
    [switch]$WithAdmin
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    & "$PSScriptRoot/stop.ps1"
    & "$PSScriptRoot/startup.ps1" -WithAdmin:$WithAdmin
} finally {
    Pop-Location
}
