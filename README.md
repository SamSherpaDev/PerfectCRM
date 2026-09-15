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
library and [Pipeline](#pipeline) are also available; see [Templates](#templates).
Sensitive traveler documents and date-of-birth data belong in PerfectBook;
do not put them in CRM notes.

Stack: Rails 8.1, Hotwire (Turbo, Stimulus, importmap), Tailwind v4, three
SQLite databases (primary, cache, queue), Solid Queue running inside Puma,
Active Storage on an S3-compatible bucket - identical to PerfectBook so
runbooks and crews transfer. PerfectCRM's Washi visual contract lives in
[docs/DESIGN.md](docs/DESIGN.md); the proposed shared package is described in
[docs/DESIGN-SYNC.md](docs/DESIGN-SYNC.md).

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
**Settings**. Quotes renders a branded empty state until its
feature lands. See [Today and follow-ups](#today-and-follow-ups), [Mail](#mail),
[Templates](#templates), and [Pipeline](#pipeline) for the live features. Settings provides appearance,
morning and pipeline digests, connections, history import, and export controls.

On phones (under 750px) a bottom tab bar holds **Today**, **Inbox**,
**Leads**, **Clients**, and **More** (Pipeline, Quotes, Templates,
Settings) while the rail hides. Signed-in builders can preview every
component of the kit at `/design` (listed nowhere in the rail) in Paper
and Night.

PerfectCRM defaults to **Paper**, the light Washi scheme. In **Settings →
Appearance**, choose **Paper** or **Night** to apply the scheme immediately
and save it automatically - the choice submits its own form, so there is no
separate Save step. The status beneath the choice confirms when it is saved.
The choice is shared across the app and persists across navigation and later
sign-ins; signed-out pages use Paper. Device reduced-motion preferences
disable the ridge and enso animations and show thinking orbs as static frames.

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
in the next 14 days), and Back from the mountains (returned in the last
7 days). Returned bookings linked to a local record offer Create review
ask. Waiting-on-you threads and the quotes count read zero until the
mail and quotes tasks land (marked TODO in `app/services/today/summary.rb`).

Tasks belong to clients, leads, or organizations. Today lists overdue tasks
and those due through the next 7 days, using the Pacific date. Tap the
circle to complete a task and record it on the subject's timeline.
Snooze until tomorrow, 3 days, next week, or a picked date to hide a task
until that date without changing its due date. The client's Follow-ups
card lists unsnoozed open tasks and lets you add a title and due date.

Tasks with a template offer Nudge, opening the client, lead, or organization
with `?template=<id>&task=<id>`. Its Suggested message panel renders the
template with the record's name, offers Copy message, and opens a prefilled
draft in your email app with Open email draft. Review and fill missing
details before sending; other placeholders follow the [Templates](#templates)
rules. Nothing sends automatically. Tasks without a template have no Nudge
link; deleting a template preserves its tasks and removes their template link.

TODO (perfectcrm-mail-out-65): Replace the Suggested message copy/mailto
fallback with the approval-only reply box, preserving the template and task
parameters.

`Tasks::Automatic` runs daily in production at 6am Pacific through
`Tasks::GenerateAutomaticJob`; see [`config/recurring.yml`](config/recurring.yml).
It proposes review asks due 3 days after return and repeat-trip nudges due
10 months after return. Late booking syncs or local contact creation still
produce eligible tasks with their original due dates. Deposit nudges require
a mirrored invoice marked sent or overdue with a positive balance, a booking
first seen at least 5 days ago, and a start date either missing or still in
the future. Review asks and repeat nudges each fire once per booking; deposit
nudges fire once per booking and invoice number. A matching local client,
organization, or lead is required; converted leads resolve to their client.
Everything is a task the captain acts on, never sent mail.

`Leads::Transition` calls `Tasks::OnStageChange` after lead stage changes
and conversion. Its task mapping is owned by
[`app/services/tasks/on_stage_change.rb`](app/services/tasks/on_stage_change.rb);
the empty mapping currently proposes no tasks.

The production 7am Pacific digest (`TodayDigestJob` + `CaptainDigestMailer`,
same schedule file) emails today's follow-ups, overdue items, replies
waiting, and departures. Task links open their records, and Open Today
opens the morning screen. It goes to the first allowlisted address.
Settings → Morning digest toggles it; it is enabled by default.

## Clients

Clients own people, tags, notes, and a timeline. Linked email appears in the
Email card; see [Mail](#mail).
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
client contact facts stay intact; conversion sets their pipeline stage to Won.
Their timeline records Returned as a lead from
the source, with the campaign in the event metadata. Multiple historical
leads can link to the same client; conversion never merges two clients.
Without a match, conversion creates a client with the lead's facts,
including its exact source and campaign, and copies people and history.
Only clients created by conversion show Started as a lead.
Both paths transfer the lead's tasks, linked conversations, and remembered
email identities to the client, then link forward and freeze the lead read-only,
with no reverse path.

Fit labels and bar colors use the supplied fit band; the CRM does not
derive a band from the numeric score. Edit lets you enter these fields
manually and add another person in the blank People fields. The n8n/Panda
AI integration and inbound API are future work; `external_ref` and timeline
kind `automation` prepare for them without running automation today.

## Mail

Email only, from `info@sherpaholidays.com` (fixed to `MAILBOX_ADDRESS`,
default `info@sherpaholidays.com`, with no additional accepted mailboxes). The CRM
connects to the personal Google account that receives this alias by IMAP with
an app password. It keeps only messages with an exact parsed mailbox address
in From, To, Cc, Bcc, Delivered-To, or X-Original-To; personal mail is skipped
without storing it. This release reads received and sent Gmail history;
composing and sending replies in CRM is future work.

Setup (captain, about 10 minutes): Google Account → Security → turn on
2-step verification → App passwords → create one named PerfectCRM → paste
it in Settings → Mailbox with the personal Google account login → Save mailbox
→ Test connection. Leaving the password blank when saving preserves the saved
password. Production encryption keys must be configured and preserved; see
[Secrets inventory](docs/operations.md#secrets-inventory).
Production sync runs every 5 minutes (`Mail::SyncJob` in `config/recurring.yml`) over
`[Gmail]/All Mail` so sent mail is included, incremental by
UIDVALIDITY/UID, threaded on `X-GM-THRID`/`X-GM-MSGID` with a
Message-ID/In-Reply-To/References fallback. Read-only IMAP: it examines
the folder and never moves, deletes, or flags server mail. Gmail labels
are an initial read-only snapshot on each message; later Gmail label changes are not refreshed.

Every kept message lands on the right client, lead, or organization
timeline (`Conversation` + `Message`, attachments via Active Storage on
the R2 bucket), threaded, newest first, with the unread mark clearing when
the thread opens. Remembered `EmailIdentity` choices take precedence,
followed by exact email matches. Unknown senders sit in triage as suggested clients -
Link to existing, Create client, Create lead, Create organization, or
Ignore sender - and the choice is remembered. Nothing is ever created
silently. Inbox tabs are Waiting on you, Waiting on them, All, and Triage,
with icons and counts. Inbox and record timelines offer Load older so complete
history is reachable, and expanded messages show their full body.

Ordinary email attachments are part of the conversation and stay in CRM storage.
There is no attachment-count cap. Files over 25 MB are skipped with a visible
message notice. Before any blob is created or uploaded, filenames, content types,
and PDF titles are screened for passport, visa, insurance, identity/ID,
date-of-birth, and scan documents. Flagged attachments are never uploaded:
only a placeholder with filename, size, type, and "held: collect in PerfectBook"
remains on the timeline, with a follow-up note to collect the document in
PerfectBook. PDF metadata is parsed in memory; unreadable or encrypted PDFs
are also held. Document bytes and PDF titles are not persisted. Attached emails are screened
recursively: sensitive enclosures become placeholders, safe enclosures remain
available, and an enclosing .eml containing a sensitive file is never uploaded. Held documents
appear in Triage even on linked conversations.
Every stored ordinary attachment still offers **Remove from CRM, collect in
PerfectBook** if the captain identifies a sensitive file that screening missed.
This deletes its stored file, records an activity event, and leaves a follow-up
note. Storage failures preserve the reference and triage retry path. Neither
holding nor removing a file changes Gmail or uploads it to PerfectBook.

Settings → Import history backfills past mail: all, since a date, or last
N months (no 90-day cap), as requested by the captain. Preview scans the whole
selected range in a background job, using server-side address SEARCH where
supported and a resumable scan otherwise. Progress and failures are visible;
commit is available only after the preview completes. Preview and import
persist UID and UIDVALIDITY checkpoints and reset the scan if the folder is
rebuilt. Import progress counts the same in-scope messages as preview; filtered
personal mail advances only the UID checkpoint. Preview counts both inbound and
outbound mail together and shows counterparties, remembered matches, duplicates,
and editable creation choices. Choose Client, Organization, Lead, or Skip per
address. Skip suppresses record creation, not message storage; unmatched threads
remain in triage. Existing matches are reused. Approved creations apply to every
chosen address, while each conversation stays linked to a single record. Use
Resume preview or Resume import after a failure. Shared domains
suggest organizations only with two or more distinct addresses on a non-public
domain or a PerfectBook partner match. Public email providers (Gmail,
Googlemail, Yahoo, Hotmail, Outlook, Live, iCloud, Me, AOL, Proton, Protonmail)
are exempt. Import respects the same exact parsed mailbox-address rule.

## Pipeline

The board at `/pipeline` draws leads and clients on one trail: New,
Chatting, Quoted, Nudged (leads), Won, Post-trip (clients), and Lost.
Each column shows its count and value. Lead values are expected amounts
entered in USD. Client values sum their mirrored PerfectBook bookings,
keeping currencies separate; until a client has a mirrored booking, its
value is the sum of its converted leads' expected values. These are
read-only booking totals, not a CRM ledger. Lead cards show source, trip
interest, days in stage, expected value, and the fit bar when scored.

Drag cards between stages, or use the Move menu with keyboard or touch.
Moving a lead to Won opens its record for the conversion review described
in [Leads](#leads). Moving to Lost opens a required-reason sheet with an
optional note; lost leads can move back to an open stage. Clients move
manually between Won and Post-trip. Filters narrow the board by source,
trip, and referrer; client trip matches use converted lead interests or
mirrored booking trip names. On the phone, a stage list shows counts and
money; tapping a stage opens its cards.

Open leads quiet for more than 7 days glow stale. Adding a note or importing
inbound or outbound mail linked to the lead counts as a touch. Linking an
existing conversation uses its latest message time; older imported mail
never overwrites a newer touch. Changing stage or editing details does not
count as contact. Nudge opens a
Suggested message panel rendered from the first active itinerary follow-up
template, with Copy message and a prefilled Open email link when the lead
has an email address. If no template is available, the panel links to
Templates. Copying or opening email does not clear staleness; record the
contact with a note if it has not synced from mail. TODO perfectcrm-mail-out-65: connect suggested
messages to the reply box and sending.

Lead transitions use `Leads::Transition`; its automation policy is documented
in that service. For the tasks hook, see [Today and follow-ups](#today-and-follow-ups). Stage moves
record `stage_change` events; conversion records `conversion` events.
`Lead#record_touch!` preserves the latest contact time; mail ingestion and
conversation linking call it through `Conversation#touch_linkable!`.

The Numbers card is independent of board filters. It shows value by stage
using the same value sources as the board, median first reply (currently
unavailable; reporting integration is pending), repeat-and-referral rate among this year's
conversions, and asks by source this month. “Out in total” sums only open
leads' expected values. The repeat-and-referral rate counts each qualifying
conversion once, including returns to existing clients and referral leads.

The one-line digest reports open and stale leads, wins this month, and open
lead value. Its production schedule is in [`config/recurring.yml`](config/recurring.yml).
Settings → Monday pipeline note controls delivery to info@sherpaholidays.com;
it is enabled by default. It is separate from the morning digest described
in [Today and follow-ups](#today-and-follow-ups); combining them is pending.

## Production shape

The Docker image is built by GitHub Actions and published to
`ghcr.io/samsherpadev/perfectcrm` after all required CI checks pass on a
`main` push. The server pulls it with `deploy/deploy.sh` and never builds. See
[docs/operations.md](docs/operations.md) for the deploy checklist, the
secrets inventory, backups, and the restore drill. Production credential and
bucket templates are in `.env.app.example` and `.env.litestream.example`;
backup cron variables are documented in the runbook.
