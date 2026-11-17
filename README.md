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
- Photos: https://topoz.kg/kyzmet-order-attachments/
- Direct frontend for local diagnostics: http://localhost:3000
- Direct API Swagger: http://localhost:5081/swagger/index.html

Caddy forwards `/api` and `/api/*` to `api:8080` and other paths to `topoz-frontend:8080`. The frontend publishes host port 3000 to container port 8080 and receives `API_PROXY_TARGET=http://api:8080` for its nginx proxy. Browser API requests must use the same-origin `/api` path; the frontend image must be built accordingly.

Browsers load photos straight from MinIO, not through the API. The API builds photo links on `MINIO_PUBLIC_URL` (`https://topoz.kg`): public photos get permanent links, private ones a `302` to a link signed for 10 minutes. A link's path starts with the bucket name (`MINIO_BUCKET`), and MinIO checks the signature against the host and the path, so Caddy forwards `GET` and `HEAD` under `/kyzmet-order-attachments/` to `minio:9000` with both unchanged; other methods there get 405. The MinIO console stays on localhost. Moving photos to a host of their own, such as `media.topoz.kg`, takes its DNS record, a Caddy site and a new `MINIO_PUBLIC_URL`.

DNS for `topoz.kg` and ports 80/443 must reach this host for public HTTPS. Host diagnostic ports can be changed in `.env.stage`. `FRONTEND_ORIGIN` is set to `https://topoz.kg`.

Caddy reads the Caddyfile when it starts, and a Caddyfile it rejects stops every site, `topoz.kg` included. After changing it, validate the file, then recreate the Caddy container:

```powershell
docker run --rm -v "$(Join-Path $PWD 'Caddyfile'):/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile
docker compose --env-file .env.stage -f docker-compose-stage.yml -f docker-compose-stage-admin.yml up -d --force-recreate --no-deps caddy
```

## Admin panel
Start with `-WithAdmin`, then open https://192.168.1.183:5083.

Sign in with the email and password of an administrator from the stage database. Development seeds `admin@demo.kg` only into an empty database. To make an existing active customer an administrator:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec api dotnet Usta.Api.dll maintenance administrator grant user@example.com
```

Admin API: http://localhost:5082/swagger/index.html

Only Caddy publishes the admin UI port, bound to `192.168.1.183:5083`. The browser reaches admin-api through admin-web; port 5082 is bound to localhost. Without `-WithAdmin`, the admin URL returns a proxy error until the admin services are started. Keep the server IP fixed; if it changes, update both Caddyfile and the Caddy port binding in docker-compose-stage.yml. Restrict inbound TCP 5083 to the intended LAN in Windows Firewall and do not forward it from the Internet.

The panel shows photos from `https://topoz.kg`, so that name must reach this host from the LAN too: through NAT loopback on the router, or a hosts entry `192.168.1.183 topoz.kg` on the client.

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

Development, test subscriptions/payments and registration without phone confirmation remain enabled; SMS mode is described below. Embedding settings are unchanged; no embedding service is started here.

### SMS

The API uses the SMS emulator unless the host sets `SMS_MODE`. To send real SMS through Nikita, set these variables in the Windows environment of the server only (System Properties → Environment Variables → User variables), never in `.env.stage`: it is committed and shared with local copies of this stack.

| Variable | Value |
| --- | --- |
| `SMS_MODE` | `live` |
| `SMS_NIKITA_LOGIN` | Nikita account login |
| `SMS_NIKITA_PASSWORD` | Nikita account password |
| `SMS_NIKITA_SENDER` | Sender name approved by Nikita |
| `SMS_NIKITA_TEST` | Optional `true`: Nikita accepts requests without delivering them |

Open a new PowerShell window so it sees the variables, then run `.\restart.ps1`; Compose prefers them to `.env.stage`. Set the first four together: `live` with the emulator's placeholder login still starts, and the first SMS fails with Nikita status 2 in the API log. Nikita must also allow the server's public IP (status 3 otherwise) and have a positive balance (status 4). Without the variables the staff route `/api/v1/test/sms/messages` shows emulated messages; in `live` it returns 404.

The main and optional admin compose files each declare the shared API environment because YAML anchors do not span files. Keep their database, storage, phone-code and data-protection settings in sync. Application credentials remain in `.env.stage`.
