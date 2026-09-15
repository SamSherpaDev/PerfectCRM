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
"PerfectBook connection" below). The client foundation currently supports leads,
clients, organizations, people, notes, search, and export. The message-template
library is also available; see [Templates](#templates). Sensitive traveler
documents and date-of-birth data belong in PerfectBook; do not put them in CRM notes.

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
(root), **Inbox**, **Leads**, **Clients**, **Pipeline**, **Quotes**, **Templates**, and
**Settings**. Today, Inbox, Pipeline, and Quotes render branded empty states until
their features land; Templates is live (see "Templates" below). Settings
provides the appearance control and the export below.

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

## Today and follow-ups

Today (the root route) is the captain's morning screen: four tiles
(Waiting on you, Follow-ups due, Quotes out, Overdue), then Replies
waiting, Follow-ups as one-tap check rows, Departing soon (trips leaving
in 14 days), and Back from the mountains (home in 7 days, each with a
one-tap Create review ask). Waiting-on-you threads and the quotes count
read zero until the mail and quotes tasks land (marked TODO in
`app/services/today/summary.rb` and the view).

`Task` belongs to a client, lead, or organization (polymorphic subject)
with a kind (`follow_up`, `document`, `payment_nudge`, `review_ask`,
`call`, `custom`), `due_on` (`due_at` optional), `done_at`,
`snoozed_until`, and `created_by` (`automation` or `captain`). Overdue,
today, and upcoming are computed on the Pacific date. Completing a task
appends an ActivityEvent to the subject's timeline. Snooze presets are
tomorrow, 3 days, next week, or a picked date. The client page's
Follow-ups card (the slot in `app/views/clients/_tasks_card.html.erb`)
lists open tasks, takes new ones, and names the suggested nudge when
opened with `?template=<id>`; the reply box that prefills it arrives
with the mail task. A Nudge link on a task without a template is hidden
until then.

`Tasks::Automatic` (run daily at 6am Pacific by
`Tasks::GenerateAutomaticJob`, see [`config/recurring.yml`](config/recurring.yml))
proposes a review ask 3 days after a booking's departure ends, a
repeat-trip nudge 10 months after return, and a deposit nudge when a
mirrored invoice reads sent with a balance due on a booking first seen
at least 5 days ago. Each fires once per booking (`idempotency_key`);
everything is a task the captain acts on, never sent mail. The pipeline
board calls `Tasks::OnStageChange.call(subject:, from:, to:)` on stage
changes; stages map to optional task templates in
`STAGE_TASK_TEMPLATES` (empty until the pipeline task fills it).

The 7am Pacific digest (`TodayDigestJob` + `CaptainDigestMailer`, same
schedule file) emails today's follow-ups, overdue items, replies
waiting, and departures with deep links to the first allowlisted
address. Settings → Morning digest toggles it.

## Clients

Clients own people, tags, notes, and the timeline later tasks fill in.
Use New client to create a record, and Edit to update facts or add another
person in the blank People fields. Archive moves a client to the Archived
tab, where Restore makes it active again. The Organizations tab holds
advisors, operators, and other companies, with their own notes and timeline.
On client, lead, and organization pages, Older/Newer links beneath notes
and timeline entries provide access to the full history.

Search covers names, emails, phone tails, tags, and note text over SQLite
FTS5 with an email-substring fallback; no external service. Each row links
to PerfectBook when `perfectbook_contact_id` is set, via
`PERFECTBOOK_BASE_URL` (default `https://perfectbook.sherpaholidays.com`).
`/clients/by-perfectbook/:id` is PerfectBook's "Open in PerfectCRM"
target; an unlinked contact opens a create form with its PerfectBook ID
prefilled, without fetching contact details.

Settings → Export everything downloads a zip containing leads, clients,
people, organizations, notes, tags, tag assignments, and timeline events as
CSV with a UTF-8 BOM. Cells beginning with `=`, `+`, `-`, or `@` receive a
leading single quote to prevent spreadsheet formula execution, including
phone numbers beginning with `+`.

## Leads

Leads are asks that have not booked yet; clients are everyone else.
A lead carries source (`google_ads`, `meta_ads`, `website_form`, `email`,
`referral`, `manual`), campaign, `external_ref` for n8n idempotency, Panda
AI fit (`fit_score`, `fit_band`, `fit_reason`), and status (`new`,
`chatting`, `quoted`, `nudged`, `lost`). Tabs are New, Chatting, Quoted,
Nudged, Lost, and Converted. An email or PerfectBook contact ID can recur
across lost or converted inquiries, but only one open lead (unconverted
and not lost) can hold each identity. `external_ref` remains unique across
all leads.

Conversion is one-way and manual. Convert to client matches an existing
client by PerfectBook contact ID first, then normalized primary email.
The confirmation names a matched client before attaching the lead's
people (deduplicated by email), tags, notes, and activity to them. Existing
client facts stay intact; their timeline records Returned as a lead from
the source, with the campaign in the event metadata. Multiple historical
leads can link to the same client; conversion never merges two clients.
Without a match, conversion creates a client with the lead's facts,
including its exact source and campaign, and copies people and history.
Only clients created by conversion show Started as a lead.
Both paths link forward and freeze the lead read-only, with no reverse path.

Fit labels and bar colors use the supplied fit band; the CRM does not
derive a band from the numeric score. Edit lets you enter these fields
manually and add another person in the blank People fields. The n8n/Panda
AI integration and inbound API are future work; `external_ref` and timeline
kind `automation` prepare for them without running automation today.

## Production shape

The Docker image is built by GitHub Actions and published to
`ghcr.io/samsherpadev/perfectcrm` after all required CI checks pass on a
`main` push. The server pulls it with `deploy/deploy.sh` and never builds. See
[docs/operations.md](docs/operations.md) for the deploy checklist, the
secrets inventory, backups, and the restore drill. Production credential and
bucket templates are in `.env.app.example` and `.env.litestream.example`;
backup cron variables are documented in the runbook.
