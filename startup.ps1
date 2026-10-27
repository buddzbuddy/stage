
$ErrorActionPreference = "Stop"

$compose = @(
    "compose",
    "--env-file", ".env.stage",
    "-f", "docker-compose-stage.yml"
)

function Run-Docker {
    & docker @compose @args
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed (exit code $LASTEXITCODE)"
    }
}

Run-Docker config --quiet
Run-Docker pull

Run-Docker up -d --wait db minio

# Wait for PostgreSQL to accept connections
$ready = $false

for ($i = 1; $i -le 30; $i++) {
    & docker @compose exec -T db sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'

    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        break
    }

    Start-Sleep -Seconds 2
}

if (-not $ready) {
    throw "PostgreSQL is not ready"
}

# Allow initialization shutdown/restart to finish
Start-Sleep -Seconds 5

Run-Docker cp stage-backup/usta.dump db:/tmp/usta.dump

# Restore with retry only for connection/startup errors
$restored = $false

for ($i = 1; $i -le 5; $i++) {
    $output = & docker @compose exec -T db sh -c 'pg_restore --exit-on-error --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/usta.dump' 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        $restored = $true
        break
    }

    $message = ($output | Out-String)
    if ($message -notmatch 'shutting down|starting up|connection refused|could not connect') {
        throw "Database restore failed: $message"
    }

    Start-Sleep -Seconds 5
}

if (-not $restored) {
    throw "Database restore failed after retries"
}

Run-Docker up -d --wait api

Invoke-RestMethod http://localhost:5081/health/ready
