
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

# Restore only into an empty database. Fail closed if the inspection fails.
$inspectionSql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND n.nspname NOT LIKE 'pg_temp_%'
) THEN 'populated' ELSE 'empty' END;
"@
$databaseState = $inspectionSql | & docker @compose exec -T db sh -c 'psql -X -A -t -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect database; restore was not attempted"
}
$databaseState = ($databaseState | Out-String).Trim()

if ($databaseState -eq 'empty') {
    Run-Docker cp stage-backup/usta.dump db:/tmp/usta.dump

    # Restore with retry only for connection/startup errors
    $restored = $false

    for ($i = 1; $i -le 5; $i++) {
        $output = & docker @compose exec -T db sh -c 'pg_restore --single-transaction --exit-on-error --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/usta.dump' 2>&1
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
} elseif ($databaseState -eq 'populated') {
    Write-Host "Existing database detected; skipping backup restore."
} else {
    throw "Unexpected database inspection result; restore was not attempted"
}

# Always fetch the current API image before starting or recreating the container.
Run-Docker up -d --wait --pull always api

Invoke-RestMethod http://localhost:5081/health/ready
