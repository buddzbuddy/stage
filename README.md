## Run Power Shell Script
.\startup.ps1

The backup is restored only when the database has no user relations (tables, views, or sequences). Subsequent runs preserve the existing database and skip restoration. Restores run in a single transaction so a failed restore does not leave partially restored data. An existing database, including one partially restored by an older script, is preserved; this check does not validate its completeness.

Every startup pulls `buddzbuddy/usta-api:latest` from the registry and recreates the API container when the image has changed. If the pull fails, startup stops.

## Stop containers
```powershell
.\stop.ps1
```

Stops and removes the staging containers and network. Database, attachment, and data protection volumes are preserved.

## Restart containers
```powershell
.\restart.ps1
```

Runs `stop.ps1`, then runs `startup.ps1` only if shutdown succeeds.

## Final API
http://localhost:5081/swagger/index.html
