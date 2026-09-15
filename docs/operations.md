# PerfectCRM operations runbook

Target: the same OVHcloud VPS that runs PerfectBook
(`perfectbook.sherpaholidays.com`), behind the same system Caddy in
`/opt/apps/caddy`. PerfectCRM lives at `/opt/apps/perfectcrm` and serves
`https://perfectcrm.sherpaholidays.com`. The server pulls the CI-built image
and never builds.

Shared-box facts — host prep, firewall, system Caddy, the `apps` network,
bucket providers, DNS, healthchecks, backup philosophy — live in
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
   Verify with `./bucket-smoke.sh` in step 5.
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
   `./bucket-smoke.sh` — it lists both buckets with the same variables the
   containers read.
5. **Compose up.** On the box, run `./deploy.sh` in `/opt/apps/perfectcrm`.
   It pulls the CI-built image, starts app and litestream, and prunes old
   images. The entrypoint runs the idempotent `db:prepare`, so migrations
   apply on every deploy. Open `https://perfectcrm.sherpaholidays.com` and
   sign in.
   While this repository is public the GHCR image needs no login. When the
   repo goes private, log the box in once with a token that has
   `read:packages` before pulling:
   `echo <token> | docker login ghcr.io -u <github-username> --password-stdin`.
6. **Healthchecks.** Create one healthchecks.io check for the nightly backup;
   put its ping URL in `HEALTHCHECKS_URL` where the cron job reads it, and
   add a free uptime check on `https://perfectcrm.sherpaholidays.com/up`.
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
| `SMTP_USERNAME`, `SMTP_PASSWORD` | Gmail app password | `.env.app`, password manager |

## Nightly backup

Second-line backup behind Litestream: `deploy/nightly-backup.sh` takes a
`sqlite3 .backup` of both databases, gzips, and `rclone`s to the backup
bucket under `nightly/`, prunes older than 30 days, and pings healthchecks.
Cron on the VPS (root):

```cron
0 3 * * * /opt/apps/perfectcrm/nightly-backup.sh
```

Requires `BACKUP_RCLONE_REMOTE` (an rclone S3 remote for the backup bucket),
`LITESTREAM_BUCKET`, and `HEALTHCHECKS_URL` in the cron environment. Run from
`/opt/apps/perfectcrm`.

## Restore drill

`deploy/restore-drill.sh` restores the Litestream replica to `/tmp`,
integrity-checks it, boots a throwaway app container against it on a random
loopback port, and curls `/up`. On success it prints the loopback URL and an
SSH-forward hint plus the cleanup command; the drill container stays up until
the operator confirms the app looks right and runs that cleanup. Quarterly,
and once before trusting backups.

## Adding another app to this server

Same pattern a third time: its own folder under `/opt/apps`, its own
`compose.yml` on the shared `apps` network with no published ports, its own
Caddy snippet, its own buckets. Nothing in this app's folder is shared.
