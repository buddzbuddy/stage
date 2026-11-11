## Start on Windows / Docker Desktop

```powershell
.\startup.ps1
# Include admin-api and admin-web:
.\startup.ps1 -WithAdmin
```

The default stack contains PostgreSQL, MinIO, API, frontend and Caddy. The optional `docker-compose-stage-admin.yml` adds the admin services. Scripts resolve paths relative to their own directory.

The backup is restored only when the database has no user relations (tables, views, or sequences). Subsequent runs preserve the existing database and skip restoration. Restores run in a single transaction so a failed restore does not leave partially restored data. An existing database, including one partially restored by an older script, is preserved; this check does not validate its completeness.

Every startup pulls all images selected by the compose files and recreates a container when its image has changed. If a pull fails, startup stops. PostgreSQL and MinIO start first; database restoration completes before API migrations run.

Caddy waits for API and frontend healthchecks. With `-WithAdmin`, the admin API starts only after the API is healthy, because only the API migrates the database. Caddy serves the admin panel over LAN HTTPS; the panel forwards `/api` to the admin API, so both share one origin. Readiness checks use container ports, independent of host port settings in `.env.stage`.

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
Start with `-WithAdmin`, then open https://192.168.1.183:5083.

Sign in with the email and password of an administrator from the stage database. Development seeds `admin@demo.kg` only into an empty database. To make an existing active customer an administrator:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec api dotnet Usta.Api.dll maintenance administrator grant user@example.com
```

Admin API: http://localhost:5082/swagger/index.html

Only Caddy publishes the admin UI port, bound to `192.168.1.183:5083`. The browser reaches admin-api through admin-web; port 5082 is bound to localhost. Without `-WithAdmin`, the admin URL returns a proxy error until the admin services are started. Keep the server IP fixed; if it changes, update both Caddyfile and the Caddy port binding in docker-compose-stage.yml. Restrict inbound TCP 5083 to the intended LAN in Windows Firewall and do not forward it from the Internet.

Caddy uses its internal certificate authority for this private IP. Export its public root certificate after startup (never distribute private keys):

```powershell
New-Item -ItemType Directory -Force certificates
docker cp topoz-caddy-stage:/data/caddy/pki/authorities/local/root.crt ./certificates/topoz-stage-root.crt
certutil -hashfile ./certificates/topoz-stage-root.crt SHA256
```

Copy `certificates/topoz-stage-root.crt` to each client device through a trusted channel. On Windows, run `certmgr.msc`, select **Trusted Root Certification Authorities / Certificates**, then **All Tasks / Import** and import this certificate for the current user. For all users, an administrator can use `certlm.msc` instead. Restart the browser. Browsers with a separate certificate store may require importing the root there as well. On iOS/iPadOS, install the certificate profile and enable full trust under Settings / General / About / Certificate Trust Settings. On Android, install it as a CA certificate in security settings (menu names vary by device).

On the server, run this once in an elevated PowerShell window to allow LAN access:

```powershell
New-NetFirewallRule -DisplayName 'TOPOZ Admin HTTPS LAN 5083' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.168.1.183 -LocalPort 5083 -RemoteAddress LocalSubnet -Profile Any
```

Open the HTTPS URL without a certificate warning and check `window.isSecureContext` in the browser console; it should be `true`. Specific browser features may still require user permissions. Trust is needed on clients, not just inside the Docker container. The `caddy_data` volume preserves the CA across normal restarts; if that volume is deleted, export and trust the new root again.

## Environment

Development, SMS emulator, test subscriptions/payments and registration without phone confirmation remain enabled. Embedding settings are unchanged; no embedding service is started here.

The main and optional admin compose files each declare the shared API environment because YAML anchors do not span files. Keep their database, storage, phone-code and data-protection settings in sync. Application credentials remain in `.env.stage`.
