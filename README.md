## Start on Windows / Docker Desktop

```powershell
.\startup.ps1
# Include admin-api and admin-web:
.\startup.ps1 -WithAdmin
# Include the request monitoring (Alloy, Loki, Grafana):
.\startup.ps1 -WithAdmin -WithMonitoring
```

The default stack contains PostgreSQL, MinIO, API, frontend and Caddy. The optional `docker-compose-stage-admin.yml` adds the admin services, `docker-compose-stage-monitoring.yml` the request monitoring. Scripts resolve paths relative to their own directory.

Before the first start, copy `.env.stage.example` to `.env.stage` and fill in the empty values. Git ignores `.env.stage`, so each host keeps its own and a pull never changes it; add a new variable of the example to it by hand.

The backup is restored only when the database has no user relations (tables, views, or sequences). Subsequent runs preserve the existing database and skip restoration. Restores run in a single transaction so a failed restore does not leave partially restored data. An existing database, including one partially restored by an older script, is preserved; this check does not validate its completeness.

Every startup pulls all images selected by the compose files and recreates a container when its image has changed. If a pull fails, startup stops. PostgreSQL and MinIO start first; database restoration completes before API migrations run.

Caddy waits for API and frontend healthchecks. With `-WithAdmin`, the admin API starts only after the API is healthy, because only the API migrates the database. Caddy serves the admin panel over LAN HTTPS; the panel forwards `/api` to the admin API, so both share one origin. Readiness checks use container ports, independent of host port settings in `.env.stage`.

Starting without `-WithAdmin` or `-WithMonitoring` does not stop an already running admin or monitoring stack. Use restart without that flag to return to the default stack.

## Stop containers
```powershell
.\stop.ps1
```

Stops and removes all staging containers, including admin and monitoring services, and the Compose-managed network. Database, attachment, data protection, Caddy, log and monitoring volumes are preserved. The network is created automatically; no external network setup is required.

## Restart containers
```powershell
.\restart.ps1
.\restart.ps1 -WithAdmin
.\restart.ps1 -WithAdmin -WithMonitoring
```

Runs `stop.ps1`, then runs `startup.ps1` with the selected flags only if shutdown succeeds.

## Application

- Frontend: https://topoz.kg
- API: https://topoz.kg/api
- Photos: https://topoz.kg/kyzmet-order-attachments/
- Direct frontend for local diagnostics: http://localhost:3000
- Direct API Swagger: http://localhost:5081/swagger/index.html

Caddy forwards `/api` and `/api/*` to `api:8080` and other paths to `topoz-frontend:8080`. The frontend publishes host port 3000 to container port 8080 and receives `API_PROXY_TARGET=http://api:8080` for its nginx proxy. Browser API requests must use the same-origin `/api` path; the frontend image must be built accordingly.

Browsers load photos straight from MinIO, not through the API. The API builds photo links on `MINIO_PUBLIC_URL` (`https://topoz.kg`): public photos get permanent links, private ones a `302` to a link signed for 10 minutes. A link's path starts with the bucket name (`MINIO_BUCKET`), and MinIO checks the signature against the host and the path, so Caddy forwards `GET` and `HEAD` under `/kyzmet-order-attachments/` to `minio:9000` with both unchanged; other methods there get 405. The MinIO console stays on localhost. Moving photos to a host of their own, such as `media.topoz.kg`, takes its DNS record, a Caddy site and a new `MINIO_PUBLIC_URL`.

DNS for `topoz.kg` and ports 80/443 must reach this host for public HTTPS. Host diagnostic ports can be changed in `.env.stage`. `FRONTEND_ORIGIN` is set to `https://topoz.kg`.

Caddy reads the Caddyfile when it starts, and a Caddyfile it rejects stops every site, `topoz.kg` included. After changing it, validate the file in a one-off Caddy container with the service's settings, then recreate the Caddy container:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
docker compose --env-file .env.stage -f docker-compose-stage.yml -f docker-compose-stage-admin.yml up -d --force-recreate --no-deps caddy
```

## Request log

Caddy writes a JSON line for every request it has answered into the `caddy_logs` volume: `topoz.log` for `topoz.kg` and `admin.log` for the admin panel. The line goes to a local file after the response, so writing it costs no network call and does not slow responses. Caddy rotates each file at 100 MiB and keeps 10 compressed copies for up to 30 days, about 250 MB on disk.

A line holds `ts`, `status`, `size` (response body bytes sent, after compression), `bytes_read` (request body bytes), `duration` in seconds, `request` (`remote_ip`, `client_ip`, `method`, `host`, `uri`, `headers`), `resp_headers` and `kind`: `api`, `photos`, `front` or `admin`, set by the Caddy route that handled the request. Caddy writes `Cookie`, `Set-Cookie`, `Authorization` and `Proxy-Authorization` values as `REDACTED`, and the log filter removes `X-Amz-Signature` and `X-Amz-Credential` from photo links, both in requested URIs and in the `Location` of the API's redirects to private photos. Request and response bodies are not logged. `resp_headers` carries the API's `X-Correlation-Id`, which leads from a log line to the API's own events.

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec caddy tail -n 5 /var/log/caddy/topoz.log
```

Docker Desktop forwards published ports from its own gateway, so `remote_ip` and `client_ip` show that gateway rather than the visitor. The frontend's nginx forwards the SignalR hub `/hubs/` to the API, so hub requests carry `kind` `front`.

## Monitoring

`-WithMonitoring` adds four services that collect the request log, the API's own log and its metrics without touching the site:

- Grafana Alloy follows `topoz.log` and `admin.log` through a read-only mount of `caddy_logs` and sends new lines to Loki. Its position in each file is kept in the `alloy_data` volume. It also reads the output of the `api` and `admin-api` containers of this Compose project through the Docker socket and receives their OpenTelemetry metrics on port 4317 inside the Compose network.
- Loki stores the log lines for 30 days in the `loki_data` volume and parses their fields when queried.
- Prometheus stores the API metrics for 90 days in the `prometheus_data` volume.
- Grafana shows them at `https://<SERVER_LAN_ADDRESS>:5084` (see Server address): the «Трафик», «API» and «Коды подтверждения» dashboards and Drilldown → Logs.

Configuration lives in `monitoring/`: `alloy/config.alloy`, `loki/config.yaml`, Grafana's data source and dashboard provisioning, and the dashboards as JSON in `grafana/dashboards/`. Alloy labels every Caddy line with `kind` and `status_class` (`2xx`…`5xx`) and attaches `route` (the path without its query, every GUID replaced by `{id}`) and `agent` (`loadtest` for k6, `bot` for bots, tools and an empty User-Agent, `browser` otherwise). At rest the four services take about 0.5 GB of memory.

Both API hosts send metrics to `alloy:4317` (`OpenTelemetry__Otlp__Endpoint`) and write their console log as JSON (`StructuredLogging__JsonConsole`), with or without the monitoring services; without them the export fails quietly in the background. Alloy labels API log lines with `job` (`api` or `admin-api`) and `level` (`information`, `warning`, `error`…), so `{job="api", level="error"}` finds the API's errors. It leaves out the Information lines of `Microsoft.AspNetCore`, `Microsoft.EntityFrameworkCore` and `System.Net.Http.HttpClient`: every SQL command, routing step and outgoing call, about nine lines and 13 KB a request. Loki keeps one line per request, plus warnings, errors and the application's own events; `docker compose logs` still shows everything. In Grafana's Explore, a Caddy line's `X-Correlation-Id` links to the API events of that request. Prometheus names the hosts `job` `Usta.Api` and `Usta.Admin.Api`; traces that the hosts send are dropped. The Docker socket also lets Alloy control every container on this host, so run the monitoring services only on a server you control.

«Коды подтверждения» shows the API's `Usta.PhoneCodes` meter: codes by channel, the share that went through WhatsApp and Telegram, refusals by channel and reason, the statuses of WhatsApp's webhook, the Telegram Gateway balance, and the cost and the savings against SMS at the prices in the variables at the top, in som with a decimal point (SMS 1.77, WhatsApp 0.67, Telegram 0.88 by default). A price typed there stays in the page's address until the dashboard is opened anew; to change a default, edit `phone-codes.json` as described below. The savings are an upper bound: a messenger code after which the user still asked for an SMS counts as saved.

Set these variables in the Windows environment of the server, like the SMS settings and never in `.env.stage`, then open a new PowerShell window and restart:

| Variable | Value |
| --- | --- |
| `GRAFANA_ADMIN_PASSWORD` | Password of the Grafana user `admin` |
| `GRAFANA_TELEGRAM_BOT_TOKEN` | Token of the Telegram bot that sends the alerts |
| `GRAFANA_TELEGRAM_CHAT_ID` | Id of the Telegram chat that receives them; a group's id is negative |

```powershell
.\restart.ps1 -WithAdmin -WithMonitoring
```

Compose refuses the monitoring file while any of them is unset. Grafana takes the password only when it creates its database; to change it later:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml -f docker-compose-stage-monitoring.yml exec grafana grafana cli admin reset-admin-password <new password>
```

Caddy serves Grafana like the admin panel, with the same internal certificate, so clients that trust the admin panel trust Grafana too. Sign-up and anonymous access are off. Allow the port on the LAN once, in an elevated PowerShell window:

```powershell
$lan = ((Get-Content .env.stage) -match '^SERVER_LAN_ADDRESS=')[0].Split('=')[1]
New-NetFirewallRule -DisplayName 'TOPOZ Grafana HTTPS LAN 5084' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $lan -LocalPort 5084 -RemoteAddress LocalSubnet -Profile Any
```

Grafana loads dashboards from the JSON files when it starts and does not let the UI save over them. To change one, edit it in Grafana, copy its JSON from Export into the file under `monitoring/grafana/dashboards/`, then restart Grafana:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml -f docker-compose-stage-monitoring.yml restart grafana
```

Stopping Loki, Alloy or Grafana does not affect the site. While Loki is down, Alloy retries and sends the missed lines once Loki is back; a restart of Alloy resumes where it stopped. Alloy saves its position every few seconds, so if Alloy is killed rather than stopped, Loki may receive the last seconds of lines twice. Lines in a file that Caddy rotated while Alloy was stopped stay only in that compressed file.

### Alerts

Every minute Alloy requests `https://topoz.kg/healthz` (`front`) and `https://topoz.kg/api/v1/auth/csrf` (`api`) through Caddy, with the site's name and certificate and the User-Agent `usta-probe`. The results go to Prometheus as `probe_success`; the requests appear in the Caddy log with `agent` `probe`, and the «Трафик» panels other than the one of agents leave them out. So the log never stays quiet for long while everything works.

Grafana evaluates the rules of `monitoring/grafana/provisioning/alerting/rules.yaml` every minute and sends firing and resolved alerts to Telegram:

| Alert | Fires when |
| --- | --- |
| Сайт не отвечает | the `front` or `api` probe gets no 200 for 2 minutes |
| API не готов | a host's `/health/ready`, which Docker's healthcheck calls, answers an error for 2 minutes: the database or storage is down |
| Доля 5xx выше 5 % | more than 5 % of at least 20 visitor requests in 5 minutes got 5xx |
| Всплеск запросов | for 2 minutes visitors send more than 5 requests a second and five times as many as in the previous hour |
| Журнал Caddy молчит | Loki has no Caddy line for 10 minutes or does not answer: Caddy, Alloy or Loki is down |
| Заканчивается баланс Telegram Gateway | the balance Telegram reported with the last paid code is below 10 |
| Мессенджер отказывает в кодах | in an hour the provider or the daily budget refused more than half of at least 5 WhatsApp or Telegram codes; a sign-in without the messenger's mark, a number without the messenger and a channel that is off do not count |
| Провайдер кодов отказывает из-за настроек или оплаты | in 10 minutes Nikita, Telegram or WhatsApp refused a code for its token, number, template or payment, a failed status of WhatsApp's webhook included; the API's error log names the error |

To set up Telegram, create a bot with @BotFather, add it to the team's group and send a message there. `https://api.telegram.org/bot<token>/getUpdates` then shows the group as `chat.id`. After the restart, Alerting → Contact points → Telegram → Test in Grafana sends a test message. Rules, the contact point and the notification policy are provisioned from files like the dashboards: change the YAML, then restart Grafana.

## Admin panel
Start with `-WithAdmin`, then open `https://<SERVER_LAN_ADDRESS>:5083`, where `SERVER_LAN_ADDRESS` in `.env.stage` is the server's IP in the LAN (see Server address).

Sign in with the email and password of an administrator from the stage database. Development seeds `admin@demo.kg` only into an empty database. To make an existing active customer an administrator:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml exec api dotnet Usta.Api.dll maintenance administrator grant user@example.com
```

Admin API: http://localhost:5082/swagger/index.html

Only Caddy publishes the admin UI port, bound to port 5083 of `SERVER_LAN_ADDRESS`. The browser reaches admin-api through admin-web; port 5082 is bound to localhost. Without `-WithAdmin`, the admin URL returns a proxy error until the admin services are started. Restrict inbound TCP 5083 to the intended LAN in Windows Firewall and do not forward it from the Internet.

The panel shows photos from `https://topoz.kg`, so that name must reach this host from the LAN too: through NAT loopback on the router, or a hosts entry `<SERVER_LAN_ADDRESS> topoz.kg` on the client.

Caddy uses its internal certificate authority for this private IP. Export its public root certificate after startup (never distribute private keys):

```powershell
New-Item -ItemType Directory -Force certificates
docker cp topoz-caddy-stage:/data/caddy/pki/authorities/local/root.crt ./certificates/topoz-stage-root.crt
certutil -hashfile ./certificates/topoz-stage-root.crt SHA256
```

Copy `certificates/topoz-stage-root.crt` to each client device through a trusted channel. On Windows, run `certmgr.msc`, select **Trusted Root Certification Authorities / Certificates**, then **All Tasks / Import** and import this certificate for the current user. For all users, an administrator can use `certlm.msc` instead. Restart the browser. Browsers with a separate certificate store may require importing the root there as well. On iOS/iPadOS, install the certificate profile and enable full trust under Settings / General / About / Certificate Trust Settings. On Android, install it as a CA certificate in security settings (menu names vary by device).

On the server, run this once in an elevated PowerShell window to allow LAN access:

```powershell
$lan = ((Get-Content .env.stage) -match '^SERVER_LAN_ADDRESS=')[0].Split('=')[1]
New-NetFirewallRule -DisplayName 'TOPOZ Admin HTTPS LAN 5083' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $lan -LocalPort 5083 -RemoteAddress LocalSubnet -Profile Any
```

Open the HTTPS URL without a certificate warning and check `window.isSecureContext` in the browser console; it should be `true`. Specific browser features may still require user permissions. Trust is needed on clients, not just inside the Docker container. The `caddy_data` volume preserves the CA across normal restarts; if that volume is deleted, export and trust the new root again.

### Server address

`SERVER_LAN_ADDRESS` in `.env.stage` is the only place that names the server's IP in the LAN. Compose binds Caddy's ports 5083 and 5084 to it, Caddy serves the admin panel and Grafana at it and issues their certificate for it, and Grafana builds its links on it. On those ports Caddy answers a request to any other address with an empty page, so reserve the IP for the server on the router. When it changes anyway:

1. Set `SERVER_LAN_ADDRESS` in `.env.stage` to the new IP.
2. Recreate Caddy and Grafana. Caddy restarts, so `topoz.kg` is down for a few seconds; without the monitoring stack, leave out its file and `grafana`:

   ```powershell
   docker compose --env-file .env.stage -f docker-compose-stage.yml -f docker-compose-stage-admin.yml -f docker-compose-stage-monitoring.yml up -d --no-deps caddy grafana
   ```

3. Move the firewall rules to the new IP, in an elevated PowerShell window:

   ```powershell
   $lan = ((Get-Content .env.stage) -match '^SERVER_LAN_ADDRESS=')[0].Split('=')[1]
   Get-NetFirewallRule -DisplayName 'TOPOZ * HTTPS LAN *' | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -LocalAddress $lan
   ```

4. Point the router's forwarding of ports 80 and 443 and the clients' `topoz.kg` hosts entries to the new IP.

Clients keep trusting the panel and Grafana: Caddy issues the certificate for the new IP from the same root in `caddy_data`.

## Environment

Development, the test subscription offer and registration without phone confirmation remain enabled; SMS mode and payments through Finik Beta are described below. Embedding settings are unchanged; no embedding service is started here.

### SMS

The API uses the SMS emulator unless the host sets `SMS_MODE`. To send real SMS through Nikita, set these variables in the Windows environment of the server only (System Properties → Environment Variables → User variables), never in `.env.stage`: local copies of this stack reuse it.

| Variable | Value |
| --- | --- |
| `SMS_MODE` | `live` |
| `SMS_NIKITA_LOGIN` | Nikita account login |
| `SMS_NIKITA_PASSWORD` | Nikita account password |
| `SMS_NIKITA_SENDER` | Sender name approved by Nikita |
| `SMS_NIKITA_TEST` | Optional `true`: Nikita accepts requests without delivering them |

Open a new PowerShell window so it sees the variables, then run `.\restart.ps1`; Compose prefers them to `.env.stage`. Set the first four together: `live` with the emulator's placeholder login still starts, and the first SMS fails with Nikita status 2 in the API log. Nikita must also allow the server's public IP (status 3 otherwise) and have a positive balance (status 4). Without the variables the staff route `/api/v1/test/sms/messages` shows emulated messages; in `live` it returns 404.

The main and optional admin compose files each declare the shared API environment because YAML anchors do not span files. Keep their database, storage, phone-code and data-protection settings in sync. Application credentials remain in `.env.stage`.

### Codes in WhatsApp and Telegram

Without the variables below, WhatsApp is off and Telegram runs on the emulator. A messenger that is on gets its button on the site, and a user who presses it gets the code in WhatsApp or Telegram. The API never moves a code to another channel on its own: a messenger that is off, out of its daily budget or refusing a code answers 400 with the reason, and the site offers SMS instead. Turn them on one at a time with a small daily budget, for example 30, check each on real phones as the acceptance on real numbers describes (`usta/backend/docs/api/sms-auth-acceptance.md` in the kyzmet_mvp repository), watch «Коды подтверждения» for a few days, then raise the budget.

WhatsApp needs a business portfolio verified by Meta and an approved authentication template. Until both are ready, leave the `WHATSAPP_*` variables unset: the API keeps WhatsApp off, and the site shows no WhatsApp button.

Set these variables in the Windows environment of the server, like the SMS settings, never in `.env.stage`:

| Variable | Value |
| --- | --- |
| `TELEGRAM_MODE` | `live` |
| `TELEGRAM_GATEWAY_TOKEN` | API token of the Telegram Gateway account |
| `TELEGRAM_DAILY_LIMIT` | Codes a day through Telegram, then SMS; 250 when unset |
| `WHATSAPP_MODE` | `live` |
| `WHATSAPP_PHONE_NUMBER_ID` | Phone number ID of the WhatsApp Business number |
| `WHATSAPP_ACCESS_TOKEN` | Permanent token of the Meta system user |
| `WHATSAPP_TEMPLATE_NAME` | Name of the approved authentication template in Russian (`ru`) |
| `WHATSAPP_APP_SECRET` | App Secret of the Meta app: the API checks the webhook's signature with it |
| `WHATSAPP_VERIFY_TOKEN` | A long random string, also typed as Verify token in the webhook settings of the Meta app |
| `WHATSAPP_DAILY_LIMIT` | Codes a day through WhatsApp, then SMS; 250 when unset, never above Meta's daily recipient limit |

Open a new PowerShell window, then run `.\restart.ps1`. Set a messenger's variables together. WhatsApp in `live` with a missing or malformed setting stops the API at startup, and Caddy waits for its healthcheck. Telegram in `live` without `TELEGRAM_GATEWAY_TOKEN` still starts with the emulator's placeholder token: Gateway refuses every code, the request answers 400 `phone_code_channel_unavailable`, and «Провайдер кодов отказывает из-за настроек или оплаты» fires. Without `TELEGRAM_MODE` the stack, which runs in Development, keeps the Telegram emulator: codes asked for in Telegram reach no phone, and the staff route `/api/v1/test/telegram/messages` shows them; in `live` it returns 404. So set `live` before the site shows the Telegram button to real users, or `disabled` to keep every code on SMS. `https://topoz.kg/api/v1/auth/phone-codes/channels` lists the messengers that are on.

Telegram takes its balance from Fragment; codes to the number of the Gateway account's owner are free, which suits the first check. The «Заканчивается баланс Telegram Gateway» alert fires below 10.

WhatsApp reports delivery to `https://topoz.kg/api/v1/webhooks/whatsapp`, which Caddy forwards with the rest of `/api`. Set `WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` and restart before saving the callback URL in the Meta app: the route answers Meta's verification request while both are set, whatever `WHATSAPP_MODE` is, and 404 without them. Then subscribe the webhook to the `messages` field. A code Meta could not deliver comes again by SMS, for the same code screen.

On this host all visitors share one address for the API's limits, so the limit of 5 code requests a minute per address holds for the whole site (see Visitor addresses).

Two to four weeks after a messenger goes on, compare the dashboard's share of messenger codes and its cost with the bills of Meta, Fragment and Nikita, and correct the price variables of the dashboard if they differ.

### Visitor addresses

The API limits requests per visitor's address: 5 code requests a minute (`RateLimiting__PhoneCodes__PermitLimit`), 12 sign-in attempts a minute (`RateLimiting__Auth__PermitLimit`) and the requests of guests in general. It takes the address from the `X-Forwarded-For` header Caddy sets, since it trusts proxies in `TRUSTED_PROXY_NETWORK`: Docker's networks, `172.16.0.0/12`, unless the variable is set. Caddy writes the address it sees into that header and ignores one a visitor sends, so a visitor cannot claim another address to dodge a limit. The API also takes the scheme from Caddy, sees HTTPS and marks its cookies Secure.

Docker Desktop has no setting that keeps visitors' addresses: Caddy sees Docker's gateway (see Request log), so on this Windows host all visitors share one address, and each per-address limit holds for the whole site: a sixth code request in a minute gets 429, whoever sends it. On a Linux host Docker keeps the addresses, and every visitor gets limits of their own without further changes. Check there that the Compose network lies inside `TRUSTED_PROXY_NETWORK`, or set the variable to its subnet:

```powershell
docker network inspect usta-stage_topoz-proxy --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

### Payments through Finik Beta

Without the variables below, subscription invoices stay on the mock provider `local-test`: a dispatcher simulates their payment. With them, the invoice the API issues on approval gets a payment page of Finik Beta, Finik's webhook confirms the payment, and the subscription becomes active without a dispatcher. Finik Beta takes no money, so its invoices and subscriptions keep the mode `test`; the address of the beta and Finik's public key come with the API image.

Set these variables in the Windows environment of the server, like the SMS settings, never in `.env.stage`:

| Variable | Value |
| --- | --- |
| `SUBSCRIPTION_PAYMENT_MODE` | `finik`; `test` or unset keeps the mock |
| `FINIK_API_KEY` | API key of the type WEB that Finik issued |
| `FINIK_ACCOUNT_ID` | ID of the Finik account that receives the payments |
| `FINIK_PRIVATE_KEY_FILE` | Path to the unencrypted private RSA key in PEM whose public half Finik holds, outside both repositories, for example `C:\topoz\secrets\finik_private.pem` |

Compose mounts the key file read-only into the API at `/run/secrets/finik_private.pem`; without `FINIK_PRIVATE_KEY_FILE` the API gets an empty file there, which only the `finik` mode reads. Docker Desktop creates a mistyped path as an empty folder; delete it after correcting the variable. With `finik`, a missing setting or a key the API cannot read, that folder included, stops the API at startup with a message naming the setting, and the API container restarts until it is fixed; Caddy waits for its healthcheck, so the site is down meanwhile. Read the message, then fix the variable or go back to `test`:

```powershell
docker compose --env-file .env.stage -f docker-compose-stage.yml logs --tail 20 api
```

The API builds both of Finik's addresses on `FRONTEND_ORIGIN`:

- The webhook `https://topoz.kg/api/v1/subscriptions/payments/webhook/finik`, which Caddy forwards with the rest of `/api`, body and headers unchanged. The API checks Finik's signature against this configured address, not against the address a request arrives at, so `FRONTEND_ORIGIN` must be the site's public HTTPS origin.
- The return to the site after paying, `https://topoz.kg/subscription/subscriptions/<subscription>?view=payment&invoice=<invoice>&from=finik`. The site team confirms the route; a new one goes into `Finik__ReturnUrl` in `docker-compose-stage.yml`.

Finik reports only successful payments and repeats a webhook until the API answers 200: five times 30 seconds apart, then twice as rarely each time, up to once a day. A payment made while the API was down is credited when Finik repeats it. While the mode is not `finik`, the webhook route answers 503, and Finik repeats too.

To turn Finik on:

1. Back up the database to a folder outside the repository, and keep the copy on the server: it holds the users' data.

   ```powershell
   docker compose --env-file .env.stage -f docker-compose-stage.yml exec -T db sh -c 'pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /tmp/before-finik.dump'
   New-Item -ItemType Directory -Force $HOME\topoz-backups
   docker compose --env-file .env.stage -f docker-compose-stage.yml cp db:/tmp/before-finik.dump $HOME\topoz-backups\before-finik.dump
   ```

2. Set `USTA_API_IMAGE` and `USTA_ADMIN_API_IMAGE` in `.env.stage` to the tag of images with Finik payments, then run `.\restart.ps1` with the flags you use. The API migrates the database and keeps the mock: check that a dispatcher still approves an application and simulates its payment.
3. Put the key file on the server, set the four variables, open a new PowerShell window and run `.\restart.ps1` again.
4. A dispatcher approves an application. `GET https://topoz.kg/api/v1/subscriptions/invoices/<invoice>` shows `"provider": "finik"`, `"mode": "test"` and `paymentUrl`. Open [Finik Playground](https://www.finik.kg/documentation/web-sdk/playground/), paste `paymentUrl` into «Провести тестовый платёж» and press «Оплатить»: within seconds the invoice is `paid` and the subscription `active`. The full acceptance is the table «Проверка» in `docs/finik-payments-plan.md` of the kyzmet_mvp repository.

Invoices issued before the switch keep the mock: a dispatcher still simulates their payment, while simulating a Finik invoice answers 409 `provider_mismatch`. The site `topoz-web:0.1.1` knows neither `provider` nor `paymentUrl`: it can show a Finik invoice's QR, which encodes the payment page, and shows its payment code as «Не предоставлен». The «Оплатить в Finik» button and the screen after the return come with the site version the site team builds from the page «Оплата через Finik для сайта TOPOZ».

To roll back, set `SUBSCRIPTION_PAYMENT_MODE` to `test` or delete it, open a new PowerShell window and run `.\restart.ps1`; if the new image itself fails, also set the image tags in `.env.stage` back to the previous ones. The previous image works with the migrated database. New invoices then go to the mock, and Finik's invoices wait: their webhooks get 503 and come again once the mode is `finik`.
