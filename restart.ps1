$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    & "$PSScriptRoot/stop.ps1"
    & "$PSScriptRoot/startup.ps1"
} finally {
    Pop-Location
}
