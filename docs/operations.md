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
| AI provider key | [AI setup](../README.md#ai-assistance) | Settings; encrypted in the primary database, password manager |
| Mailbox login and app password | [Mail setup](../README.md#mail) | Settings; app password encrypted in the primary database, password manager |
| `PERFECTBOOK_BASE_URL`, `PERFECTBOOK_API_TOKEN` | [PerfectBook connection setup](../README.md#perfectbook-connection) | CRM `.env.app`; token also in PerfectBook's `.env.app` and password manager |

Preserve the Active Record encryption keys with database backups and supply the
same keys when restoring. Losing or replacing them makes encrypted values
unreadable, including the mailbox app password, AI provider key, lead phone fields, and relay
secret. For relay credential setup and rotation, see the
[website intake contract](leads-intake.md#relay-mode-n8n-panda-ai-any-server).

## PerfectBook connection

For configuration, sync behavior, and the Settings connection check, see
[PerfectBook connection](../README.md#perfectbook-connection).

## First sign-in setup

Most setup lives in Settings; the PerfectBook credentials require box access.
Work top to bottom; each Settings card saves itself.

1. **Appearance.** Pick Paper or Night. It applies the moment you choose
   it.
2. **Mailbox.** Settings → Mailbox: the Gmail address receiving the
   `info@sherpaholidays.com` alias plus its app password (Google Account →
   Security → 2-step verification → App passwords, named PerfectCRM),
   then Test connection. Sync runs every 5 minutes over `[Gmail]/All Mail`,
   read-only. Then Settings → Import history → Preview to backfill recent
   mail before triaging. See [Mail](../README.md#mail).
3. **Email replies.** Your name and signature. Every reply sends as
   `info@sherpaholidays.com` with these attached. See
   [Replying](../README.md#replying).
4. **AI drafts.** The provider key, then Edit voice to set the voice guide
   the drafts are written in. Nothing sends without Send. See
   [AI assistance](../README.md#ai-assistance).
5. **Automations.** The public site key for the storefront form; the relay
   secret and webhook URL for n8n and Panda AI. Rotate either credential
   from the same card after pasting the new value at the other end. See the
   [website intake contract](leads-intake.md).
6. **PerfectBook.** Set `PERFECTBOOK_BASE_URL` and
   `PERFECTBOOK_API_TOKEN` in `/opt/apps/perfectcrm/.env.app` on the box.
   From `/opt/apps/perfectcrm`, run
   `docker compose -f compose.yml up -d --force-recreate app`.
   Settings shows connection status and Test connection; it does not edit
   these credentials. Use Test connection after recreating the container. See
   [PerfectBook connection](../README.md#perfectbook-connection).
7. **Digests.** The 7am Today mail and the Monday pipeline note are on by
   default; turn either off from its card.

## Daily operations

All from `/opt/apps/perfectcrm` on the box.

- **Logs.** `docker compose -f compose.yml logs -f app` (add
  `litestream` for the replicator).
- **Restart.** `docker compose -f compose.yml up -d` recreates anything
  stopped; `./deploy.sh` also pulls the newest green image first.
- **Deploy a version.** `./deploy.sh` pulls and runs `:latest` (last green
  `main`). To pin one: `IMAGE_TAG=<commit-sha> ./deploy.sh`.
- **Rollback.** `IMAGE_TAG=<previous-sha> ./deploy.sh`, then confirm
  `/up` and sign in. The entrypoint's `db:prepare` only migrates forward,
  so roll back data from the nightly backup first if the bad deploy
  migrated the schema.
- **Health.** `https://perfectcrm.sherpaholidays.com/up` (uptime check)
  plus the healthchecks.io nightly-backup ping (backup check).

## Nightly backup

Second-line backup behind Litestream: `deploy/nightly-backup.sh` takes a
`sqlite3 .backup` of the primary and queue databases (the disposable cache is
excluded), gzips, and `rclone`s to the backup bucket under `nightly/`, prunes
older than 30 days, and pings healthchecks.
Cron on the VPS (root):

```cron
0 3 * * * /opt/apps/perfectcrm/nightly-backup.sh
```

Requires `BACKUP_RCLONE_REMOTE` (an rclone S3 remote for the backup bucket),
`LITESTREAM_BUCKET`, and `HEALTHCHECKS_URL` in the cron environment. Run from
`/opt/apps/perfectcrm`.

## Restore drill

`deploy/restore-drill.sh` restores the primary Litestream replica to an
isolated writable directory under `${TMPDIR:-/tmp}` (queue and cache are
recreated by `db:prepare`),
integrity-checks it, boots a throwaway app container against it on a random
loopback port, and curls `/up`. On success it prints the loopback URL and an
SSH-forward hint plus the cleanup command; the drill container stays up until
the operator confirms the app looks right and runs that cleanup. Quarterly,
and once before trusting backups.

### Signed-in verification over HTTPS

On the laptop, have Caddy available and add
`https://localhost:8443/auth/google_oauth2/callback` to the authorized redirect
URIs of the Google web OAuth client whose ID is in the server's `.env.app`.
Keep the production redirect URI. The callback must match exactly, including
scheme and port ([Google redirect URI rules](https://developers.google.com/identity/protocols/oauth2/web-server#uri-validation)).

1. Run the SSH command printed by the drill in a laptop terminal and leave
   it running. It forwards laptop port 18080 to the restored app's random
   server loopback port.
2. In a local working directory on the laptop, create `Caddyfile.drill`:

   ```caddyfile
   {
       admin 127.0.0.1:20199
       auto_https disable_redirects
   }

   https://localhost:8443 {
       bind 127.0.0.1
       tls internal
       reverse_proxy 127.0.0.1:18080
   }
   ```

   Run `caddy run --config Caddyfile.drill --adapter caddyfile` and leave it
   running. This laptop proxy supplies HTTPS and preserves the localhost
   host and port for OAuth; the VPS Caddy configuration stays unchanged.
3. In another laptop terminal, run
   `caddy trust --address 127.0.0.1:20199` and approve the local CA trust
   prompt if needed. If the browser uses a separate certificate store,
   import the Caddy root certificate shown in the Caddy logs there too.
   See [Caddy's trust command](https://caddyserver.com/docs/command-line#caddy-trust).
4. Open `https://localhost:8443`, sign in with the allowlisted Google account,
   and open Today and Settings. Database writes go to the isolated
   restored copy. Open a known ordinary email attachment as well; attachment
   reads still use the configured production bucket.
5. Run the cleanup command printed by the drill on the VPS, stop both laptop
   terminal processes with Ctrl-C, and remove the temporary localhost
   redirect URI from the Google client.

## Adding another app to this server

Same pattern a third time: its own folder under `/opt/apps`, its own
`compose.yml` on the shared `apps` network with no published ports, its own
Caddy snippet, its own buckets. Nothing in this app's folder is shared.
