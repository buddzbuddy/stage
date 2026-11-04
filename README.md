## Start on Windows / Docker Desktop

```powershell
.\startup.ps1
# Include admin-api and admin-web:
.\startup.ps1 -WithAdmin
```

The default stack contains PostgreSQL, MinIO, API, frontend and Caddy. The optional `docker-compose-stage-admin.yml` adds the admin services. Scripts resolve paths relative to their own directory.

The backup is restored only when the database has no user relations (tables, views, or sequences). Subsequent runs preserve the existing database and skip restoration. Restores run in a single transaction so a failed restore does not leave partially restored data. An existing database, including one partially restored by an older script, is preserved; this check does not validate its completeness.

Every startup pulls all images selected by the compose files and recreates a container when its image has changed. If a pull fails, startup stops. PostgreSQL and MinIO start first; database restoration completes before API migrations run.

Caddy waits for API and frontend healthchecks. With `-WithAdmin`, the admin API starts only after the API is healthy, because only the API migrates the database. The admin panel forwards `/api` to the admin API, so both share one origin. Neither admin service passes through Caddy. Readiness checks use container ports, independent of host port settings in `.env.stage`.

Starting without `-WithAdmin` does not stop an already running admin stack. Use restart without that flag to return to the default stack.

## Stop containers
```powershell
.\stop.ps1
```

Stops and removes all staging containers, including admin services, and the Compose-managed network. Database, attachment, data protection and Caddy volumes are preserved. The network is created automatically; no external network setup is required.

## Restart containers
```powershell
.\restart.ps1
.\restart.ps1 -WithAdmin
```

Runs `stop.ps1`, then runs `startup.ps1` with the selected admin flag only if shutdown succeeds.

## Application

- Frontend: https://topoz.kg
- API: https://topoz.kg/api
- Direct frontend for local diagnostics: http://localhost:3000
- Direct API Swagger: http://localhost:5081/swagger/index.html

Caddy forwards `/api` and `/api/*` to `api:8080` and other paths to `topoz-frontend:8080`. The frontend publishes host port 3000 to container port 8080 and receives `API_PROXY_TARGET=http://api:8080` for its nginx proxy. Browser API requests must use the same-origin `/api` path; the frontend image must be built accordingly.

DNS for `topoz.kg` and ports 80/443 must reach this host for public HTTPS. Host diagnostic ports can be changed in `.env.stage`. `FRONTEND_ORIGIN` is set to `https://topoz.kg`.

## Admin panel
Start with `-WithAdmin`, then open http://localhost:5083.

Sign in with the email and password of an administrator from the stage database. Development seeds `admin@demo.kg` only into an empty database. To make an existing active customer an administrator:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec api dotnet Usta.Api.dll maintenance administrator grant user@example.com
```

Admin API: http://localhost:5082/swagger/index.html

The panel and the admin API listen on localhost by default. For LAN access, set `ADMIN_BIND_ADDRESS` to the server LAN address (for example `192.168.1.10`) or `0.0.0.0`, rerun startup with `-WithAdmin`, then open `http://<server-LAN-IP>:5083`. Allow the panel port in Windows Firewall for the intended LAN. The browser reaches admin-api through admin-web; port 5082 remains bound to localhost.

## Environment

Development, SMS emulator, test subscriptions/payments and registration without phone confirmation remain enabled. Embedding settings are unchanged; no embedding service is started here.

The main and optional admin compose files each declare the shared API environment because YAML anchors do not span files. Keep their database, storage, phone-code and data-protection settings in sync. Application credentials remain in `.env.stage`.
