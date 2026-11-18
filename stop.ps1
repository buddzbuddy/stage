$ErrorActionPreference = "Stop"

# The monitoring file needs the Grafana password even for down, so its services go as orphans.
& docker compose --env-file "$PSScriptRoot/.env.stage" -f "$PSScriptRoot/docker-compose-stage.yml" -f "$PSScriptRoot/docker-compose-stage-admin.yml" down --remove-orphans
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose shutdown failed (exit code $LASTEXITCODE)"
}
