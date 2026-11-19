[CmdletBinding()]
param(
    [switch]$WithAdmin,
    [switch]$WithMonitoring
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    & "$PSScriptRoot/stop.ps1"
    & "$PSScriptRoot/startup.ps1" -WithAdmin:$WithAdmin -WithMonitoring:$WithMonitoring
} finally {
    Pop-Location
}
