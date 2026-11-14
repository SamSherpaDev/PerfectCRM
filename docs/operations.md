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
   `deploy/drive-backup.sh`, `deploy/drive-attachments-backup.sh`, `deploy/restore-drill.sh`,
   `deploy/bucket-smoke.sh`. Create `.env.app` and
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
6. **Healthchecks.** Follow [Nightly backup](#nightly-backup) and
   [Drive backup](#drive-backup) for backup monitoring and add a free uptime check on
   `https://perfectcrm.sherpaholidays.com/up`.
7. **Restore drill.** Run `./restore-drill.sh` once before trusting backups
   (section "Restore drill" below), then quarterly.
8. **Record secrets.** Every value from the secrets inventory is in the
   password manager as well as on the box. Nothing secret is in git.

## Continuous database backups

Litestream 0.5.9 replicates both `storage/production.sqlite3` and
`storage/production_queue.sqlite3` to `perfectcrm/primary` and
`perfectcrm/queue` in the backup bucket. Both use a 20 s database monitor
interval and 1 s replica sync: worst-case loss is about 21 s plus upload
time, with a 24-48 h point-in-time restore window.

`deploy/litestream.yml` keeps checkpoints hourly, compaction levels at
5 m / 1 h / 6 h, L0 retention at 5 m with an hourly sweep, and daily
snapshots retained for 25 h. These settings reduce R2 request costs while
keeping at least 24 h of restore history. Litestream silently ignores
unknown or misplaced keys; monitor/checkpoint belong on each database,
sync on each replica, and retention/compaction settings at the top level.
The allowlist test in `test/deploy/litestream_config_test.rb` guards this.

To update the bind-mounted configuration, save the current server file as
`litestream.yml.prev`, copy `deploy/litestream.yml` into place, then run
`docker compose -f compose.yml restart --timeout 40 litestream`. Do not use
`up -d`: Compose does not detect content changes inside the bind mount.
Check logs for replication of both databases, 1 s replica sync, the configured
monitor intervals, and no errors or database-initialisation timeouts. Run
the restore drill and restore the queue separately; after at least 2 h,
verify point-in-time restores of both databases from before and after the
switch. To roll back, copy `litestream.yml.prev` over `litestream.yml` and
restart only Litestream the same way.

## Secrets inventory

| Variable | Comes from | Stored |
| --- | --- | --- |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `bin/rails db:encryption:init` | `.env.app`, password manager |
| `SECRET_KEY_BASE` | `bin/rails secret` | `.env.app` on box, password manager |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Step 1 | `.env.app`, password manager |
| `ALLOWED_GOOGLE_EMAILS` | [Google sign-in allowlist](../README.md#google-sign-in) | `.env.app`, password manager |
| `SPACES_*` (attachments bucket + keys) | Step 2 | `.env.app`, password manager |
| `LITESTREAM_*`, backup-bucket `SPACES_ENDPOINT`/`SPACES_REGION` | Step 2 | `.env.litestream`, password manager |
| `perfectcrm-attachments` rclone remote (read-only attachments-bucket token), `ATTACHMENTS_BUCKET` | [Attachments backup](#attachments-backup), `ATTACHMENTS_ACCESS=remote` only | Root's rclone configuration and `.env.nightly-backup`, password manager |
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
  and error logs. Rails retains request logs under the
  [request-log filtering policy](../README.md#google-sign-in).
  Rails serves static assets, compresses
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
  and [Nightly backup](#nightly-backup) plus [Drive backup](#drive-backup)
  for backup monitoring.

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
`IMAGE_TAG=latest` (the deployment's current image tag), plus the
`ATTACHMENTS_*` settings in [Attachments backup](#attachments-backup).
`HEALTHCHECKS_URL` stays unset because the owner chose not to configure
backup alerts. If that choice changes, its optional ping URL belongs in this
environment file.
Check `/var/log/perfectcrm-nightly-backup.log` as root for backup results
and the expected warning about the missing ping. PerfectBook uses its
own `.env.nightly-backup`, remote, and `/var/log/perfectbook-nightly-backup.log`
with the same cron command shape. The scripts change into their app directory.

## Drive backup

A daily encrypted copy of both databases in the owner's Google Drive, beside
(never instead of) Litestream and the nightly R2 copy. The Google sign-in
client, the `sherpa-drive` and `sherpa-backup` rclone remotes, the encryption
key, the owner's private key copy, and recovery without the server are
box-wide and live in PerfectBook's runbook, section "Drive backup"
(`https://github.com/SamSherpaDev/BK-app/blob/main/docs/operations.md#drive-backup`).
This section covers only the CRM job.

`deploy/drive-backup.sh` takes the same `sqlite3 .backup` copies of the
primary and queue databases as the nightly backup, gzips them, and uploads
them through the encrypting `sherpa-backup` crypt remote, so Drive shows
only scrambled file and folder names. Inside the remote it writes, named by
the UTC date of the run:

```
perfectcrm/daily/production-YYYY-MM-DD.sqlite3.gz
perfectcrm/daily/production_queue-YYYY-MM-DD.sqlite3.gz
perfectcrm/monthly/production-YYYY-MM-DD.sqlite3.gz      (and production_queue-)
```

- **Verification.** After each upload, `rclone cryptcheck --one-way`
  decrypts what landed on Drive and compares it with the local copy; a
  mismatch fails the job.
- **Retention.** Daily copies are deleted after 30 days and monthly copies
  after 365 days. Drive keeps deleted files in its trash for 30 more days.
- **Monthly copies.** The first successful run of each month adds a monthly
  copy of each database, so a missed or failed 1st is covered by the next
  run that month. A database whose monthly copy for that month (any day) is
  already on Drive gets no second one.
- **Reruns.** A copy already on Drive for that day is left untouched, so a
  same-day rerun uploads nothing and takes no new snapshot.
- **No file contents.** The archives hold attachment records only, never
  file bytes. Ordinary attachments have their own hourly mirror
  ([Attachments backup](#attachments-backup)).

`deploy/perfectcrm-drive-backup.timer` starts
`deploy/perfectcrm-drive-backup.service` daily at 11:45 UTC (03:45 Pacific
standard time, 04:45 in summer), after the 03:15 Pacific nightly backup and
15 minutes after PerfectBook's Drive job. `Persistent=false`, so a missed run
is not caught up at boot. The oneshot service reuses the root-owned
`.env.nightly-backup` (only `IMAGE_TAG` matters here), points rclone at
root's configuration with `RCLONE_CONFIG`, and appends to
`/var/log/perfectcrm-drive-backup.log`. Install, once the box-wide remotes
exist:

```sh
sudo install -m 755 drive-backup.sh restore-drill.sh /opt/apps/perfectcrm/
sudo install -m 644 perfectcrm-drive-backup.service perfectcrm-drive-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now perfectcrm-drive-backup.timer
systemctl list-timers perfectcrm-drive-backup.timer
```

Run it once by hand with `sudo systemctl start perfectcrm-drive-backup.service`;
`systemctl show perfectcrm-drive-backup.service -p Result -p ExecMainStatus`
must read `success` and `0`. The owner declined alerts, so there is no
healthchecks ping: the job exits nonzero on any failure, and its unit result,
log, and next run in `systemctl list-timers` are where failures show. Check
them during routine server work and before relying on a restore. Then prove
the copy restores with the drill's Drive source ([Restore drill](#restore-drill)).

Limits: Drive alone can lose up to a day of data (Litestream on R2 stays the
roughly 20-second recovery-point layer); the server's own Google access can
permanently delete what it wrote, so the locked R2 copies stay; and losing
the encryption key loses every Drive copy.

### Attachments backup

An hourly encrypted mirror of ordinary CRM email attachments in the same
Drive backup, beside (never instead of) the R2 attachments bucket. Ordinary
attachments and held identity documents share that bucket under random keys,
so the job never lists the bucket: the app's database alone decides what may
be copied, and held documents never qualify, so their 24-hour deletion
(README, "Mail") still holds.

- **Allowlist.** `bin/rails backup:attachment_manifest`
  (`AttachmentBackup.manifest`) prints the key of every file attached to a
  CRM message, except held documents in any state (live, expired, a failed
  purge, or an upload still in flight), files marked potentially sensitive
  (which includes every file sent to PerfectBook), files whose name or type
  the import screening (`Message.sensitive_attachment?`) flags, and keys
  outside Active Storage's format. Draft-only files and the signature logo
  are not message files and are not copied. The output is a header, keys,
  and an `end N` trailer, never filenames.
- **Layout.** Inside the `sherpa-backup` crypt remote each file is one object
  named by its blob key, `perfectcrm/attachments/<key>`, so Drive shows only
  scrambled names. The key is also the object's name in the bucket.
- **Each run.** The manifest must match its format exactly; a stray log
  line, a missing trailer, a count mismatch, or a bad key fails the run
  before any Drive call. The job then permanently deletes copies whose keys
  left the allowlist, uploads new keys from the bucket, and decrypts each new
  upload on Drive with `rclone cryptcheck --one-way` to compare it with the
  bucket's bytes. If the upload or that check fails, the run permanently
  deletes that run's new copies and fails, so the next run uploads and checks
  them again; copies from earlier runs stay. A key the bucket lacks is skipped
  and counted. Each run logs one line of counts only:
  `<UTC time> Attachments backup: kept K, new N, removed G, not in bucket M.`
- **Current state only.** The folder mirrors today's allowlist. A file
  removed from the CRM, sent to PerfectBook, or newly flagged loses its copy
  on the next successful run, normally within an hour; an empty allowlist
  removes every copy. Deletion uses `--drive-use-trash=false` on this path
  only (database pruning keeps the trash), and copies are never overwritten,
  so Drive keeps no trash entry or older revision. Anything Google keeps after a delete is encrypted. The
  mailbox keeps the original messages.
- **Rule changes.** A widened name or type rule drops matching stored files
  on the next run. A rule that needs the file bytes is not re-applied to
  stored files; it needs a one-off rescreen that marks matching blobs
  sensitive (see the comment on `Message.sensitive_attachment?`).

`deploy/perfectcrm-attachments-backup.timer` starts the oneshot
`deploy/perfectcrm-attachments-backup.service` every hour at minute 20 UTC,
clear of the 11:30 and 11:45 UTC database jobs that use the same Google
sign-in. `Persistent=false`, and a oneshot never overlaps itself, so a long
first run only absorbs its own later ticks. The service reuses
`.env.nightly-backup`, points rclone at root's configuration with
`RCLONE_CONFIG`, and appends to `/var/log/perfectcrm-attachments-backup.log`.
Run it only through systemd (`sudo systemctl start
perfectcrm-attachments-backup.service`), never the script directly.

**Bucket read access.** The host's backup credentials reach only the backup
bucket, so the job needs read access to the attachments bucket.
`ATTACHMENTS_ACCESS` in `.env.nightly-backup` selects how, and the job
refuses to run until it is set. The owner chooses one:

- `ATTACHMENTS_ACCESS=remote`: a `perfectcrm-attachments` remote in root's
  rclone configuration holding a Cloudflare R2 API token limited to "Object
  Read only" on the attachments bucket, plus `ATTACHMENTS_BUCKET=<attachments
  bucket name>` in `.env.nightly-backup`. The job can then never change or
  delete live files. The owner enters the token on the server with this
  command; the values never appear on screen or in command arguments, and the
  endpoint is copied from the existing `perfectcrm-backups` remote:

  ```sh
  sudo bash -c 'set -eu; conf=/root/.config/rclone/rclone.conf
  ! grep -q "^\[perfectcrm-attachments\]" "$conf" || { echo "perfectcrm-attachments already exists." >&2; exit 1; }
  endpoint="$(sed -n "/^\[perfectcrm-backups\]/,/^\[/s/^endpoint *= *//p" "$conf")"
  [ -n "$endpoint" ] || { echo "perfectcrm-backups has no endpoint." >&2; exit 1; }
  read -rsp "Read-only access key ID: " id; echo
  read -rsp "Read-only secret access key: " secret; echo
  printf "\n[perfectcrm-attachments]\ntype = s3\nprovider = Cloudflare\naccess_key_id = %s\nsecret_access_key = %s\nendpoint = %s\nno_check_bucket = true\n" "$id" "$secret" "$endpoint" >> "$conf"'
  ```

  Then `sudo rclone lsf --max-depth 1 perfectcrm-attachments:<bucket> | wc -l`
  must print more than 0, and a test write such as
  `echo probe | sudo rclone rcat perfectcrm-attachments:<bucket>/permission-probe`
  must fail. If the write succeeds, the token is not read-only: delete the
  probe object and replace the token.
- `ATTACHMENTS_ACCESS=app-keys`: the app's existing read-write attachment
  keys (`SPACES_ENDPOINT`, `SPACES_REGION`, `SPACES_BUCKET`,
  `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY` in `.env.app`), as
  `bucket-smoke.sh` uses them. No owner step, but a backup job then holds
  delete rights over live attachments. The script reads only those lines as
  data, never sources `.env.app`, and hands them to rclone through its
  environment.

**Install and enable**, once the database Drive backup runs and the new image
is deployed. Install the new `restore-drill.sh` with the job: its Drive source
fails until the first attachments run completes.

```sh
sudo install -m 755 drive-attachments-backup.sh restore-drill.sh /opt/apps/perfectcrm/
sudo install -m 644 perfectcrm-attachments-backup.service perfectcrm-attachments-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Before enabling, set the access option and check the size. The eligible bytes
are about what the mirror adds to Drive, which shares the owner's Google
storage with PerfectBook's documents, both apps' database archives, Gmail,
and Photos. If they exceed half the free space, stop and ask the owner about
storage. If `rclone about` is refused under the `drive.file` scope, read the
free space in Drive's web settings.

```sh
sudo docker exec -e RAILS_LOG_LEVEL=error perfectcrm-app bin/rails backup:attachment_summary
sudo rclone about sherpa-drive:
sudo systemctl enable --now perfectcrm-attachments-backup.timer
sudo systemctl start --no-block perfectcrm-attachments-backup.service
```

The summary prints counts and bytes only (`eligible_files`, `eligible_bytes`,
`held_files`, `flagged_files`, `unexpected_key_files`). When the first run
ends, `systemctl show perfectcrm-attachments-backup.service -p Result -p
ExecMainStatus` must read `success` and `0`; `sudo rclone lsf --files-only
sherpa-backup:perfectcrm/attachments | wc -l` should match `eligible_files`,
give or take files that arrived since; and the next hourly log line should
show 0 new and 0 removed. Then run the Drive drill
([Restore drill](#restore-drill)).

**Restore.** Copy the mirror back into the bucket with a remote that can
write to it: `rclone copy sherpa-backup:perfectcrm/attachments
<write remote>:<bucket>`. Active Storage uses each key unchanged as the
object name, so restored files land where the database expects them. Before
restoring a production database from any backup, stop
`perfectcrm-attachments-backup.timer` and keep it stopped until the data is
reconciled; otherwise the older database prunes the copies of newer files.
Those files are still in R2 and upload again once the timer runs.

Limits: there are no alerts (the owner's choice), so if the job breaks, for
example because the Google sign-in is revoked, copies of files removed during
the outage stay on Drive, encrypted, until it runs again. A sensitive file
the screening misses is copied, just as it is stored in R2, and the captain's
removal reaches Drive within the hour.

## Restore drill

Run quarterly and once before trusting backups. On the VPS, with the deployed
`restore-drill.sh`, `litestream.yml`, and `.env.litestream` in place:

```sh
ssh -o BatchMode=yes ubuntu@40.160.139.122
cd /opt/apps/perfectcrm
sudo ./restore-drill.sh
```

To restore from the Drive backup instead of Litestream, run
`sudo RESTORE_SOURCE=drive ./restore-drill.sh` (the default is
`RESTORE_SOURCE=litestream`; any other value fails before any work). It
lists `sherpa-backup:perfectcrm/daily` with root's rclone configuration,
takes the newest `production-` and `production_queue-` archives by date,
and streams each through `gzip -dc` into the scratch directory. A missing
archive or one that does not download and decompress fails the drill before
any boot. Both databases must pass the integrity check; the boot and record
probe below are the same. This source needs neither `.env.litestream` nor
`litestream.yml`, and no container gets network access.

The Drive source also checks the [attachments mirror](#attachments-backup)
against the restored database before booting. The restored image, still
without network, asks the app's own rule (`AttachmentBackup`) for the keys it
keeps off Drive and for the ordinary files, newest first, and writes both
only into the drill's scratch directory. The drill fails if
`sherpa-backup:perfectcrm/attachments` cannot be listed, if any copy there
belongs to a held, in-flight, or flagged file (the captain's marker or the
name and type screening), or if the newest ordinary attachment with a copy
is more than 3 hours older than the newest ordinary attachment (one missed
hourly run plus the archive's timing). It then downloads that copy and
compares its MD5 with the checksum the database recorded. A restored
database without ordinary attachments passes with nothing to probe. Output
is counts and pass/fail only, never keys or filenames. The Litestream source
makes no attachment checks.

The freshness check compares the archive with today's mirror and cannot see
production, so it can fail on a healthy backup in two cases. A Drive drill
started between 11:45 and 12:20 UTC can fail on files that reached the
archive just before it and are not mirrored yet; rerun it after 12:20 UTC.
And if the newest restored attachments were removed from the CRM or sent to
PerfectBook after the archive was taken, the next hourly run deleted their
copies as designed; the failure says so, and the drill should be rerun after
the next daily archive.

To verify a candidate script without replacing the installed one, copy it to a
scratch path and run `sudo bash /tmp/<candidate>/restore-drill.sh /opt/apps/perfectcrm`.
The optional argument selects the config directory; it does not select production
storage. Remove that candidate directory afterward.

The drill uses the immutable image ID of the running `perfectcrm-app`, rather
than resolving `latest` or another tag. It restores into a new writable
directory under `${TMPDIR:-/tmp}`. The default Litestream source restores
only the primary replica with `restore -config /etc/litestream.yml -o
/restore/production.sqlite3 /rails/storage/production.sqlite3`, so the
replica's configured R2 endpoint, region, bucket, and credentials apply.
Only the Litestream restore container has network access and reads
`.env.litestream`; it downloads the replica and never starts replication or
writes to the backup bucket. The production storage volume is never mounted.

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

This is an offline primary-database boot test. Apart from the Drive source's
attachments mirror probe, it does not verify signed-in pages, encryption-key
recovery, queue recovery, or attachment availability in the bucket. Those
require a separately planned acceptance check; production credentials,
network access, and attachment bucket reads are intentionally outside this drill.
The drill never writes production data, so the attachments timer may keep
running during it; stop the timer only before a real production restore
([Attachments backup](#attachments-backup), "Restore").

## Adding another app to this server

Same pattern a third time: its own folder under `/opt/apps`, its own
`compose.yml` on the shared `apps` network with no published ports, its own
Caddy snippet, its own buckets. Nothing in this app's folder is shared.
