# PerfectCRM operations runbook

Target: the same OVHcloud VPS that runs PerfectBook
(`perfectbook.sherpaholidays.com`), behind the same system Caddy in
`/opt/apps/caddy`. PerfectCRM lives at `/opt/apps/perfectcrm` and serves
`https://perfectcrm.sherpaholidays.com`. The server pulls the CI-built image
and never builds.

Shared-box facts - host prep, firewall, system Caddy, the `apps` network,
bucket providers, DNS, healthchecks, backup philosophy - live in
PerfectBook's runbook
(`https://github.com/SamSherpaDev/BK-app/blob/main/docs/operations.md`) and
are not repeated here. This file covers only what differs for the CRM.

## Deployment checklist

1. **Google Cloud OAuth client.** A separate web client from PerfectBook's:
   Google Cloud Console > APIs & Services > Credentials > Create Credentials >
   OAuth client ID (Web application) with the redirect URI in
   [Google sign-in](../README.md#google-sign-in). Save the client ID and
   secret into the password manager.
2. **Buckets (S3-compatible).** Two private buckets: one for attachments,
   one for database backups (Cloudflare R2 by default; Backblaze B2 works the
   same). One key pair scoped to the attachments bucket, a separate pair
   scoped to the backup bucket. Save all four keys in the password manager.
   Verify with `./bucket-smoke.sh` in step 4.
3. **DNS.** The apex and www stay on Shopify. Add one A record for host
   `perfectcrm` pointing at the VPS IPv4 (plus AAAA if IPv6), TTL 300 during
   setup. Keep port 80 reachable for the HTTP-01 challenge.
4. **Copy files.** Into `/opt/apps/caddy`, append
   `deploy/Caddyfile.snippet` to the system `Caddyfile` and reload Caddy.
   Into `/opt/apps/perfectcrm`: `deploy/compose.yml` as `compose.yml`,
   `deploy/litestream.yml`, `deploy/deploy.sh`, `deploy/nightly-backup.sh`,
   `deploy/restore-drill.sh`, `deploy/bucket-smoke.sh`. Create `.env.app` and
   `.env.litestream` from `.env.app.example` and `.env.litestream.example`,
   root-owned mode 600. Then verify bucket access with
   `./bucket-smoke.sh` - it lists both buckets with the same variables the
   containers read.
5. **Compose up.** On the box, run `./deploy.sh` in `/opt/apps/perfectcrm`.
   It pulls the CI-built image, starts app and litestream, and prunes old
   images. The entrypoint runs the idempotent `db:prepare`, so migrations
   apply on every deploy. Confirm both containers are up and Litestream is
   replicating before moving on:

   ```sh
   docker compose -f compose.yml ps
   docker compose -f compose.yml logs litestream --tail 20  # expect "replicating"
   curl -s -o /dev/null -w "%{http_code}\n" https://perfectcrm.sherpaholidays.com/up
   ```

   Open `https://perfectcrm.sherpaholidays.com` and sign in.
   While this repository is public the GHCR image needs no login. When the
   repo goes private, log the box in once with a token that has
   `read:packages` before pulling:
   `echo <token> | docker login ghcr.io -u <github-username> --password-stdin`.
6. **Healthchecks.** Follow [Nightly backup](#nightly-backup) for backup
   monitoring and add a free uptime check on
   `https://perfectcrm.sherpaholidays.com/up`.
7. **Restore drill.** Run `./restore-drill.sh` once before trusting backups
   (section "Restore drill" below), then quarterly.
8. **Record secrets.** Every value from the secrets inventory is in the
   password manager as well as on the box. Nothing secret is in git.

## Secrets inventory

| Variable | Comes from | Stored |
| --- | --- | --- |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `bin/rails db:encryption:init` | `.env.app`, password manager |
| `SECRET_KEY_BASE` | `bin/rails secret` | `.env.app` on box, password manager |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Step 1 | `.env.app`, password manager |
| `ALLOWED_GOOGLE_EMAILS` | [Google sign-in allowlist](../README.md#google-sign-in) | `.env.app`, password manager |
| `SPACES_*` (attachments bucket + keys) | Step 2 | `.env.app`, password manager |
| `LITESTREAM_*`, backup-bucket `SPACES_ENDPOINT`/`SPACES_REGION` | Step 2 | `.env.litestream`, password manager |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | Microsoft 365 SMTP credentials | `.env.app`, password manager |
| `MS_GRAPH_CLIENT_ID`, `MS_GRAPH_CLIENT_SECRET`, `MS_GRAPH_TENANT_ID` | [Microsoft 365 mailbox](#microsoft-365-mailbox) | `.env.app`, password manager |
| `CHANNEL_CHECKS_TOKEN` | Owner-created bearer credential for the channels manager | `.env.app`, password manager |
| AI provider key | [AI setup](../README.md#ai-assistance) | Settings; encrypted in the primary database, password manager |
| Mailbox grant (delegated) | [Mail setup](../README.md#mail) | Refresh token encrypted in the primary database (Settings → Mailbox → Connect mailbox), password manager |
| `PERFECTBOOK_BASE_URL`, `PERFECTBOOK_API_TOKEN` | [PerfectBook connection setup](../README.md#perfectbook-connection) | CRM `.env.app`; token also in PerfectBook's `.env.app` and password manager |
| `PERFECTBOOK_INQUIRY_TOKEN` | Owner-created bearer credential for the [inquiry lookup](source-reporting.md#link-review) | CRM `.env.app`, password manager; supply privately to the separately filed PerfectBook validation integration |

Preserve the Active Record encryption keys with database backups and supply the
same keys when restoring. Losing or replacing them makes encrypted values
unreadable, including the mailbox grant, AI provider key, lead phone fields, and relay
secret. For relay credential setup and rotation, see the
[website intake contract](leads-intake.md#relay-mode-n8n-panda-ai-any-server).

## Channel checks

The owner sets `CHANNEL_CHECKS_TOKEN` in the app environment and supplies the
same credential privately to the channels manager. Never commit, print or
include it in a URL. Unset, empty or whitespace-only disables all snapshot and
weekly and daily spend requests, including otherwise valid callers. This credential is independent of
website intake and mailbox credentials. To rotate, the owner replaces it in
both environments and applies the app environment change through the normal
release process; there is no UI token generator or manual check entry.

The aggregate-only snapshot, weekly spend and daily spend endpoints are documented in
[channel checks](channel-checks.md). The page is under Channels in the Settings
navigation group and under More on phones. Checks are retained for later trends.

## Microsoft 365 mailbox

Reading uses delegated OAuth, limited to the captain's own mailbox: no
tenant-wide Mail.Read grant and no Exchange application access policy.
Sending still goes through `smtp.office365.com:587` with the existing
SMTP settings and is unchanged by this setup.

1. **Register the application.** Microsoft Entra admin center → Identity →
   Applications → App registrations → New registration. Name it
   PerfectCRM, single tenant (Accounts in this organizational directory
   only). Note the Application (client) ID and Directory (tenant) ID.
2. **Add the redirect URI.** Authentication → Add a platform → Web →
   `https://perfectcrm.sherpaholidays.com/auth/microsoft/callback`.
   Keep the default authorization-code settings; no ID tokens needed.
3. **Add the delegated scopes.** API permissions → Add a permission →
   Microsoft Graph → Delegated permissions → `offline_access`, `Mail.Read`,
   `User.Read`. Grant admin consent for the tenant.
4. **Create a secret.** Certificates & secrets → New client secret, save
   the value (it shows once).
5. **Copy into `.env.app`.** `MS_GRAPH_CLIENT_ID`, `MS_GRAPH_TENANT_ID`,
   `MS_GRAPH_CLIENT_SECRET`. From `/opt/apps/perfectcrm`, run
   `docker compose -f compose.yml up -d --force-recreate app` to apply.
6. **Connect in Settings.** Settings → Mailbox → Connect mailbox → approve
   as info@sherpaholidays.com → Test connection. Approving while signed in
   to any other Microsoft account is refused by name and stores nothing, so
   sign out of Microsoft first if the browser holds a personal account.

For which folders are read, what the first connect takes, token-expiry
recovery, the history backfill, and reconnecting after a revoked grant, see
[Mail](../README.md#mail).

## PerfectBook connection

For configuration, sync behavior, and the Settings connection check, see
[PerfectBook connection](../README.md#perfectbook-connection).

## First sign-in setup

Follow the [first sign-in walkthrough](getting-started.md) for Settings
and the daily workflow. Configure storefront and relay credentials using
[the website intake contract](leads-intake.md). For digest delivery controls,
see [Today and follow-ups](../README.md#today-and-follow-ups) and
[Pipeline](../README.md#pipeline).

PerfectBook setup requires box access. Follow the credential configuration
in [PerfectBook connection](../README.md#perfectbook-connection), editing
`/opt/apps/perfectcrm/.env.app` on the box. From `/opt/apps/perfectcrm`, run
`docker compose -f compose.yml up -d --force-recreate app` to apply the CRM
environment changes. Then use Settings → PerfectBook → Test connection.

## Daily operations

All from `/opt/apps/perfectcrm` on the box.

- **Logs.** `docker compose -f compose.yml logs -f app` (add
  `litestream` for the replicator). Compose runs Rails/Puma directly on port
  80 behind the system Caddy, bypassing Thruster and its unfiltered access
  and error logs. Rails retains request logs with customer parameters and
  quote capability paths filtered. Rails serves static assets, compresses
  responses with Rack::Deflater, and sends download bodies without X-Sendfile
  offloading.
  This takes effect when the updated compose file is installed and the app
  container is recreated. Historical logs are not rewritten; configured Docker
  log rotation ages them out as its retention limits are reached.
- **Restart.** `docker compose -f compose.yml up -d` recreates anything
  stopped; `./deploy.sh` also pulls the newest green image first.
- **Deploy a version.** `./deploy.sh` pulls and runs `:latest` (last green
  `main`). To pin one: `IMAGE_TAG=<commit-sha> ./deploy.sh`.
- **Rollback.** First review migrations applied since the target version
  and verify that version against an isolated copy of the current database.
  The entrypoint's `db:prepare` does not undo migrations. Additive changes,
  such as the demo manifest table, can remain compatible with the previous
  app. When compatible, keep the current database and run
  `IMAGE_TAG=<previous-sha> ./deploy.sh`, then confirm `/up`, sign in, and
  check the affected workflows. If incompatible, prefer a forward fix that
  preserves current data. Restore a backup only when recovery actually
  requires it: stop app and job writes, preserve consistent copies of the
  current primary and queue databases, and identify changes since the
  backup that would be lost or need reconciliation before restoring.
- **Lead archive migration rename.** The `20260919032300` migration is
  idempotent, so databases that already applied `202609190323` need no
  `DELETE FROM schema_migrations` before or after deploy. The stale
  `202609190323` row is harmless and may be removed.
- **Health.** `https://perfectcrm.sherpaholidays.com/up` (uptime check)
  and [Nightly backup](#nightly-backup) for backup monitoring.

## Nightly backup

Second-line backup behind Litestream: `deploy/nightly-backup.sh` takes a
`sqlite3 .backup` of the primary and queue databases (the disposable cache is
excluded), gzips, and `rclone`s to the backup bucket under
`nightly/perfectcrm/`, prunes older than 30 days, and optionally pings
healthchecks. If `HEALTHCHECKS_URL` is unset or empty, it logs a warning to
stderr and still backs up. When set,
the ping uses `curl --fail`, so an HTTP error fails the job.

Root's rclone configuration (`/root/.config/rclone/rclone.conf`, mode 600)
has a separate S3 remote for each app: `perfectcrm-backups` and
`perfectbook-backups`, using each app's existing backup-bucket credentials
from `.env.litestream`. Both use `provider=Cloudflare` and
`no_check_bucket=true` for R2 object-scoped credentials, as described in
[Cloudflare's rclone guide](https://developers.cloudflare.com/r2/examples/rclone/).
These credentials stay on the VPS.

Both apps currently use the `perfectbook-backups` bucket. PerfectCRM writes
`nightly/perfectcrm/production-YYYY-MM-DD.sqlite3.gz` and
`nightly/perfectcrm/production_queue-YYYY-MM-DD.sqlite3.gz` (UTC dates).
PerfectBook uses `nightly/perfectbook/` so matching database names and dates
cannot overwrite the other app's backups. Each script prunes only its own
prefix after 30 days.

Root cron runs PerfectBook at 03:00 and PerfectCRM at 03:15 in server time
(`America/Los_Angeles`). PerfectCRM's entry is:

```cron
15 3 * * * /bin/bash -c 'set -ae; . /opt/apps/perfectcrm/.env.nightly-backup; exec /opt/apps/perfectcrm/nightly-backup.sh' >> /var/log/perfectcrm-nightly-backup.log 2>&1
```

The root-owned, mode-600 `/opt/apps/perfectcrm/.env.nightly-backup` supplies
`BACKUP_RCLONE_REMOTE=perfectcrm-backups`, `LITESTREAM_BUCKET`, and
`IMAGE_TAG=latest` (the deployment's current image tag). `HEALTHCHECKS_URL`
stays unset because the owner chose not to configure backup alerts. If that
choice changes, its optional ping URL belongs in this environment file.
Check `/var/log/perfectcrm-nightly-backup.log` as root for backup results
and the expected warning about the missing ping. PerfectBook uses its
own `.env.nightly-backup`, remote, and `/var/log/perfectbook-nightly-backup.log`
with the same cron command shape. The scripts change into their app directory.

## Restore drill

Run quarterly and once before trusting backups. On the VPS, with the deployed
`restore-drill.sh`, `litestream.yml`, and `.env.litestream` in place:

```sh
ssh -o BatchMode=yes ubuntu@40.160.139.122
cd /opt/apps/perfectcrm
sudo ./restore-drill.sh
```

To verify a candidate script without replacing the installed one, copy it to a
scratch path and run `sudo bash /tmp/<candidate>/restore-drill.sh /opt/apps/perfectcrm`.
The optional argument selects the config directory; it does not select production
storage. Remove that candidate directory afterward.

The drill uses the immutable image ID of the running `perfectcrm-app`, rather
than resolving `latest` or another tag. It restores the primary Litestream
replica into a new writable directory under `${TMPDIR:-/tmp}`. The restore
uses `restore -config /etc/litestream.yml -o /restore/production.sqlite3
/rails/storage/production.sqlite3`, so the replica's configured R2 endpoint,
region, bucket, and credentials apply. Only the Litestream restore container
has network access and reads `.env.litestream`; it downloads the replica and
never starts replication or writes to the backup bucket. The production
storage volume is never mounted.

Before booting, `PRAGMA integrity_check` must return exactly `ok`; an error,
empty result, or any diagnostic fails the drill. The app then boots in production
mode from the restored copy, with these deliberate drill-only settings:

- Docker `--network none`, no published ports, and an internal loopback listener.
  Both `/up` and the Rails record probe run through `docker exec`.
- `.env.app` is never loaded. No production OAuth, SMTP, R2 attachment, webhook,
  PerfectBook, AI, or other integration credentials are passed to the app.
- Rails generates a throwaway session secret with `SECRET_KEY_BASE_DUMMY=1`.
  Neither the real `SECRET_KEY_BASE` nor the Active Record encryption keys are
  needed: the record probe selects only an unencrypted `User` ID and never
  decrypts columns. Encrypted integration values still exist in the restored
  database, but the drill neither reads nor uses them.
- `SOLID_QUEUE_IN_PUMA` is absent (setting it to `false` would still start the
  plugin). The Active Job test adapter stores enqueues without executing them,
  mail delivery is disabled, attachments use local disk, and cache uses memory.
  No queue workers, scheduler, migrations, seeds, or `db:prepare` run. Queue and
  cache backups are outside this boot test.

Success means the restored image served `/up` and Rails read an existing `User`
record without logging any record fields. A missing record, database/read error,
boot failure, or cleanup failure makes the command exit nonzero. Every normal
exit, including failure and handled interrupt/termination, attempts both app
container removal and scratch removal, reporting any cleanup errors. The final
`Restore drill passed` message appears only after both cleanup steps succeed;
there is no manual container cleanup after a successful run. If Docker or the
filesystem prevents cleanup, resolve the reported failure and remove the named
container/directory before repeating the drill.

This is an offline primary-database boot test. It does not verify signed-in
pages, encryption-key recovery, queue recovery, or attachment availability.
Those require a separately planned acceptance check; production credentials,
network access, and attachment bucket reads are intentionally outside this drill.

## Adding another app to this server

Same pattern a third time: its own folder under `/opt/apps`, its own
`compose.yml` on the shared `apps` network with no published ports, its own
Caddy snippet, its own buckets. Nothing in this app's folder is shared.
