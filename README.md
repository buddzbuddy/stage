## Run Power Shell Script
.\startup.ps1

The backup is restored only when the database has no user relations (tables, views, or sequences). Subsequent runs preserve the existing database and skip restoration. Restores run in a single transaction so a failed restore does not leave partially restored data. An existing database, including one partially restored by an older script, is preserved; this check does not validate its completeness.

Every startup pulls `buddzbuddy/usta-api:latest`, `buddzbuddy/usta-admin-api:latest` and `buddzbuddy/usta-admin-web:latest` from the registry and recreates a container when its image has changed. If a pull fails, startup stops.

The stack runs five containers: the API, the admin API, the admin panel, PostgreSQL and MinIO. The admin API starts only after the API is healthy, because only the API migrates the database. The admin panel container serves the Angular application and forwards `/api` to the admin API, so both share one origin.

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

## Admin panel
http://localhost:5083

Sign in with the email and password of an administrator from the stage database. Development seeds `admin@demo.kg` only into an empty database. To make an existing active customer an administrator:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec api dotnet Usta.Api.dll maintenance administrator grant user@example.com
```

Admin API: http://localhost:5082/swagger/index.html

The panel and the admin API listen on localhost only. To open the panel to the LAN, set `ADMIN_BIND_ADDRESS=0.0.0.0` and restrict access with a firewall.
