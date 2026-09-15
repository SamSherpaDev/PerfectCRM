# PerfectCRM

PerfectCRM is the client relationship and communication hub for Sherpa
Holidays, a small US-based family-run Himalayan adventure-travel company. It
is the sibling of
[PerfectBook](https://github.com/SamSherpaDev/BK-app) (bookkeeping and
compliance, live at `perfectbook.sherpaholidays.com`); PerfectCRM will live
at `perfectcrm.sherpaholidays.com` on the same VPS.

PerfectBook stays the system of record for bookings, invoices, and money.
The CRM owns people, conversations, quotes, tasks, and the pipeline, and
reads PerfectBook through a small versioned, token-authenticated API (see
"PerfectBook connection" below).

Stack: Rails 8.1, Hotwire (Turbo, Stimulus, importmap), Tailwind v4, three
SQLite databases (primary, cache, queue), Solid Queue running inside Puma,
Active Storage on an S3-compatible bucket - identical to PerfectBook so
runbooks and crews transfer. The look is inherited from PerfectBook's Washi
contract in [docs/DESIGN.md](docs/DESIGN.md).

## Local development

```sh
bin/setup --skip-server
bin/dev
```

Open http://localhost:3000; `/up` reports application health. The root opens
Google sign-in; only accounts in the environment allowlist can enter. After
signing in, the root opens Today. SQLite and local uploads live in
`storage/`; development and tests need no bucket credentials.

For a credentials-free local sign-in, run
`GOOGLE_AUTH_TEST_MODE=true ALLOWED_GOOGLE_EMAILS=captain@example.test bin/dev`
and use the Google button. This development-only mode uses a fixed mock
captain identity and is ignored in production; never use it with business
data.

Bullet reports potential N+1 queries in development through `log/bullet.log`
and the Rails log. It runs without browser alerts or a page footer;
configuration lives in `config/environments/development.rb`.

## Navigation

On desktop, hover or focus the icon rail to reveal navigation labels and Sign
out. On mobile, use Open menu to show the drawer. The rail holds **Today**
(root), **Inbox**, **Clients**, **Pipeline**, **Quotes**, **Templates**, and
**Settings**. Inbox, Clients, Pipeline, and Quotes render branded empty
states until their features land; Templates is live (see "Templates"
below).

PerfectCRM defaults to **Paper**, the light Washi scheme. In **Settings →
Appearance**, choose **Paper** or **Night** to apply the scheme immediately
and save it automatically - the choice submits its own form, so there is no
separate Save step. The status beneath the choice confirms when it is saved.
The choice is shared across the app and persists across navigation and later
sign-ins; signed-out pages use Paper. Device reduced-motion preferences
disable the ridge and enso animations.

## Templates

Templates are the messages the captain sends over and over (first reply,
itinerary follow-up, deposit nudge, document request, pre-trip briefing,
during-trip check-in, review ask, repeat nudge), email only, always from
info@sherpaholidays.com. The index groups them by kind with Active /
Archived tabs carrying counts; each row shows its usage count and last use
so dead templates get pruned. New/edit pairs the form with a live preview
pane and a placeholder chooser that inserts at the cursor.

Placeholders (`{{first_name}}`, `{{trip}}`, `{{balance_due}}`, and friends -
the full list is `TemplateRenderer::PLACEHOLDERS`) render through
`TemplateRenderer` against a plain-hash context, so the mail and
PerfectBook tasks can supply real values later without changing that code.
Unknown placeholders render as a visible `[missing: name]` marker, never
blank. Seeded from `db/seeds/templates.rb` (idempotent; reruns never
overwrite captain edits).

The reply box (a later mail task) embeds `templates/_picker`: a compact
searchable list backed by `GET /templates/picker.json`, which returns each
row rendered and ready to insert. Tapping Insert records a use and emits a
window `template:insert` event with `{ id, subject, body }` detail for the
reply box to catch. Group departures get a merge preview at
`GET /templates/merge`: pick a template, paste `Name <email>` lines, and
review every rendered message. Nothing sends from there; the mail task
consumes the `MergeBatch` value object (`app/models/merge_batch.rb`).

## Google sign-in

Its own OAuth client will be created by the captain: create a Google OAuth
web client with
`https://perfectcrm.sherpaholidays.com/auth/google_oauth2/callback` as its
authorized redirect URI (use
`http://localhost:3000/auth/google_oauth2/callback` for real local OAuth).
The app requests only `openid`, `email`, and `profile`. Put only the company
address, `info@sherpaholidays.com`, in `ALLOWED_GOOGLE_EMAILS`; no other
Google account can sign in. For real local sign-in, export
`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and `ALLOWED_GOOGLE_EMAILS`
before starting `bin/dev`.

The callback verifies the ID token signature, issuer, audience, expiry and
verified email before checking the case-insensitive allowlist. Users are
keyed by Google's stable `sub`, never email. A verified email absent from the
allowlist gets a "Not allowed" page; unverified emails and other sign-in
failures get a "Sign-in failed" retry page. Neither failure creates a
session, and there is no registration page. Visiting `/auth/failure`,
including after cancelling Google consent, preserves an existing valid
session. Production cookies are Secure, HttpOnly and SameSite=Lax; sessions
expire after 12 hours of inactivity, and Sign out (`DELETE /sign-out`) clears
the cookie session. After an updated allowlist takes effect in the running
app, removing an email also denies its existing session on its next request;
`/up` stays public.

## PerfectBook connection

PerfectBook (live at `perfectbook.sherpaholidays.com`) stays the system
of record for bookings, invoices, money, and every sensitive traveler
document. The CRM mirrors contacts, the trip and departure catalog, and
customer booking and invoice status. It never stores passport, visa,
insurance, or date-of-birth data. Production polling is scheduled in
[`config/recurring.yml`](config/recurring.yml); these recurring jobs are
not scheduled in development. `PerfectBook::Catalog` and the
`perfectbook_contact_url` and `perfectbook_booking_url` helpers support
the future quote builder and client booking cards; those screens are not
implemented yet.

Configure with `PERFECTBOOK_BASE_URL` (defaults to
`https://perfectbook.sherpaholidays.com`) and `PERFECTBOOK_API_TOKEN`
(see `.env.app.example`). Generate the token with `bin/rails secret` and
set the same value in PerfectBook's `.env.app`, then recreate both app
containers so the environment changes take effect. A collection read
returning 404 is treated as an unconfigured PerfectBook API. The client
(`PerfectBook::Client` in `lib/perfectbook/`) uses conditional ETag requests
and cursor pagination. Booking polling paces requests, pauses on 429 using
`Retry-After` (60 seconds when absent), and persists its contact position
so a later run resumes after an interruption. Catalog and contact polling
record and raise rate-limit errors; they do not pause and retry within the
run. Timeouts fail fast, and repeated connection or server failures open
a per-process circuit for a cooldown (see `lib/perfectbook/circuit.rb`).
Request logs omit the token and Authorization header; Rails parameters
also filter the token (`config/initializers/filter_parameter_logging.rb`).

Settings → PerfectBook connection shows configured/unconfigured, the last
successful sync, the last error, and a Test connection button.

## Checks

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
shellcheck -S warning deploy/*.sh test/deploy/*.sh
bash test/deploy/test_deploy.sh
```

## Production shape

The Docker image is built by GitHub Actions and published to
`ghcr.io/samsherpadev/perfectcrm` after all required CI checks pass on a
`main` push. The server pulls it with `deploy/deploy.sh` and never builds. See
[docs/operations.md](docs/operations.md) for the deploy checklist, the
secrets inventory, backups, and the restore drill. Production credential and
bucket templates are in `.env.app.example` and `.env.litestream.example`;
backup cron variables are documented in the runbook.
