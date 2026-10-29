$ErrorActionPreference = "Stop"

& docker compose --env-file "$PSScriptRoot/.env.stage" -f "$PSScriptRoot/docker-compose-stage.yml" down
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose shutdown failed (exit code $LASTEXITCODE)"
}
