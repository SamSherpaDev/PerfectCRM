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
library, outbound email, [Pipeline](#pipeline), and approval-only
[AI assistance](#ai-assistance) are also available; see [Templates](#templates)
and [Replying](#replying). Sensitive traveler documents
and date-of-birth data belong in PerfectBook; do not put them in CRM notes.

Stack: Rails 8.1, Hotwire (Turbo, Stimulus, importmap), Tailwind v4, three
SQLite databases (primary, cache, queue), Solid Queue running inside Puma,
Active Storage on an S3-compatible bucket - identical to PerfectBook so
runbooks and crews transfer. PerfectCRM's Washi visual contract lives in
[docs/DESIGN.md](docs/DESIGN.md); the proposed shared package is described in
[docs/DESIGN-SYNC.md](docs/DESIGN-SYNC.md).

For the first sign-in walkthrough and local demo data, see
[Getting started](docs/getting-started.md).

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
**Settings**. See [Today and follow-ups](#today-and-follow-ups), [Mail](#mail),
[Replying](#replying), [Templates](#templates), [Pipeline](#pipeline), and [Quotes](#quotes) for the live features. Settings provides appearance,
morning and pipeline digests, connections, history import, automation settings, email sender settings, and export controls.

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

Placeholders render through `TemplateRenderer` against live values; see
[Replying](#replying) for context resolution and missing-value behavior.
The placeholder chooser uses `TemplateRenderer::PLACEHOLDERS` as its source.
Templates are seeded from `db/seeds/templates.rb` (idempotent; reruns never
overwrite captain edits).

The reply box embeds a searchable template picker. Insert fills the subject
and inserts the body at the cursor for review; usage is counted when a
message is queued, not when a template is inserted. Duplicate places the
copy at the end of the ordering, where Move up/down still works. Delete
archives a template referenced by any message, draft, or group send;
unreferenced templates are deleted. For departure merges, see
[Replying](#replying).

## Replying

Replies send as `info@sherpaholidays.com` through the Microsoft 365 SMTP
submission endpoint (`smtp.office365.com:587`, `SMTP_USERNAME`/`SMTP_PASSWORD`
plus `MAIL_FROM` in `.env.app.example`), with
`From` and `Reply-To` on the mailbox, `In-Reply-To`/`References` from the
thread, a generated `Message-ID` that is kept, the signature from Settings → Email replies,
and uploaded attachments, subject to the [mail document restrictions](#mail).
Delivery runs on Solid Queue
(`OutboundDeliveryJob`, retries with backoff); the timeline shows each
message as queued, sending, sent, or failed. A failure retains the queued
message and any saved draft. Retry on the timeline resends that message;
it does not pick up later draft edits.

The reply box docks at the bottom of the client, lead, organization, and
inbox thread views: recipient chips prefilled from the thread, `Re:`
subject, a plain-text editor, attachments, one-tap template chips and the full picker
(filled from live data), a booking select when several mirrored bookings
exist, Save draft per conversation, and Send. On a phone, tap Reply or
Resume reply to open the composer; Details holds recipients, subject,
booking choice, and attachments. New message starts a separate conversation
regardless of subject. Saved attachments accompany newly uploaded files;
a successful delivery clears the submitted draft only if it has not been
edited since submission. Nothing sends without the captain pressing Send.

Template inserts and group sends resolve identity from the recipient's
actual email, preferring their own mirrored PerfectBook contact and bookings.
Only when that contact is absent do booking values fall back to the owning
CRM record; the booking reference names that owner. CRM advisor relationships
remain available independently of the recipient's identity. Replies default
to the booking with the latest start date, preferring active bookings, and
let you choose another; a group departure uses a booking for that departure.
Unknown or empty placeholder values render `[missing: name]`, never blanks
or an email substituted for an unknown name. Sample values appear only in
the labeled template-editor preview. Set Your name and Signature in
Settings → Email replies and press Save email settings; these values also
fill templates for recipients without CRM records.

In Templates → Merge preview, select a template and a departure to fill the
recipient list from mirrored bookings, or paste one `Name <email>` or bare
email per line. Bookings without email are counted and omitted. Preview merge
shows personal messages and retains malformed lines with line numbers;
fix or remove them before sending. Review missing-value markers before
pressing Send personal emails. Each message is logged on a matching client
or open lead timeline (including matches through their people). Recipients
without a match remain supported and are logged only in the batch summary;
no CRM record is created. The summary shows delivery counts and Retry for
failed messages, including recipients without a CRM record.

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
customer booking and invoice status, plus the per-traveler document-status
summary and checklist flags. It never stores passport, visa,
insurance, or date-of-birth data long-term: the only exception is the
temporary hand-off holding area described under [Mail](#mail). Production
polling is scheduled in
[`config/recurring.yml`](config/recurring.yml); these recurring jobs are
not scheduled in development. `PerfectBook::Catalog` feeds the quote
builder, and the `perfectbook_contact_url` and `perfectbook_booking_url`
helpers power the client booking cards; see "Quotes" below.

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

## Quotes

Quotes are built from the mirrored trip catalog and sent as email plus a
Washi-styled PDF (`QuotePdf`, via `prawn`), always from
`info@sherpaholidays.com` through the app's SMTP settings. The
builder (`/quotes/new?client_id=` or `?lead_id=`) picks a trip, then a
departure with seats from the latest PerfectBook sync. Prices stay the
captain's to enter because PerfectBook exposes no catalog price, and prefill
from the newest earlier
sent or accepted quote by the same captain, preferring the same departure
and falling back to the same trip (`Quote.last_unit_for_trip`). In the new
builder, changing the trip or departure preserves entered lines, edited
descriptions and prices, and notes; untouched catalog labels and prefilled
prices refresh for the selection. Enter prices and deposits without commas
(for example, `1500.00`). Trip and departure
lines snapshot catalog names and dates at build time, so later
PerfectBook edits never rewrite history; custom lines cover permits,
single supplements, and extra nights. Revisions chain through
`parent` with a bumped `version` and supersede the old accept link; duplicates
start fresh. Only drafts can be edited, including their trip and departure.
Drafts are private: the old public page says a newer quote is on its way,
and links to the revision only once it has been sent. Accepted quotes
cannot be revised. Inclusions are entered per quote; “Remember these
inclusions for this trip” saves CRM-owned preferences separately from the
trip mirror. Remembered inclusions load on the initial trip selection when
the field is untouched. New quotes default to two guests and a valid-until
date 14 days from today. Drafts may omit these fields; sending requires a
positive party size, at least one line, a recipient email, and a valid-until
date of today or later. Drafts can retain past dates, but these must be
updated before sending. Validation errors appear in the builder. Sending a quote
moves a lead from New or Chatting to Quoted (`Quote#deliver!`). If the
email cannot be queued, the quote remains a draft and shows a retry message;
saved edits are retained. Edits commit before email enqueueing. After a lead
converts, its quotes use the client's current contact details and record new
quote activity on the client timeline.

Each quote carries an unguessable tap-to-accept link (`/q/:token`, no
sign-in). Public views are rate-limited and logged through `QuoteView`.
After `valid_until`, the page remains readable but acceptance is disabled.
Accepting records `accepted_at`, queues an email to the captain at
`info@`, writes the timeline, and stages an intake payload on the quote
page in the "Create booking in PerfectBook" panel. Its "Open PerfectBook
booking page" button opens
PerfectBook's new-booking page with the intake details in query parameters
and a copyable version alongside for manual entry. Both use the intake details
saved at acceptance, so later client edits do not change the staged intake.
The captain reviews
and creates the actual booking in PerfectBook. If the acceptance notice
cannot be queued, acceptance is rolled back and the client is asked to retry.
A direct post replaces the manual intake step once
PerfectBook ships its enquiry-creation endpoint (see
`TODO(pb-inquiry-intake)` in `Quote#perfectbook_intake_url`).

Client and lead pages (when linked to a PerfectBook contact) show
"Bookings in PerfectBook": each mirrored booking with ref, trip, dates,
status, total, paid, balance due, invoice badge and number, and "Open in
PerfectBook", plus a Refresh button that re-pulls just that contact
(`PerfectBook::SyncBookingsJob` with `perfectbook_contact_id`). Refresh
runs in the background; reload the page after the sync completes.
PerfectBook mirrors each booking's traveler documents summary (per traveler:
first name plus received/missing/expiring per document type, with the
booking-level missing count; never contents or values) and checklist done
flags (`documents_json`, `missing_count`, `checklist_json` on
`PerfectBook::Booking`, stored by `SyncBookingsJob`; the ETag flow is
unchanged). Each booking card shows every traveler with a badge per
document type and the missing count. While anything is outstanding the card
links "Nudge for missing documents", which opens the reply box, including on
phones, and prefills an empty draft using the active document-request template.
The `missing_documents` placeholder names each traveler and their missing or
expiring document types; the booking reference and dates accompany the text.
If no active template exists, built-in copy includes that missing list.
Existing drafts are preserved. The action disappears when no tracked documents
are missing or expiring. The copy page (`document-nudge/:booking_id`) offers
the same text to review and an "Open in reply box" shortcut when documents are
outstanding. If the mirror has no document summary yet, the card links to the
copy page with a reminder to check PerfectBook manually. Today lists the
mirrored missing count on departing-soon rows.

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

Today (the root route) is the captain's morning screen: six tiles
(Waiting on you, Follow-ups due, Quotes out, Overdue, New leads, Active
clients), then Replies waiting, Follow-ups as one-tap check rows,
Departing soon (trips leaving in the next 14 days), and Back from the
mountains (returned in the last 7 days). Returned bookings linked to a
local record offer Create review ask. Waiting on you counts linked threads
where the client wrote last (same rule as the Inbox tab; unknown senders
wait in triage), Replies waiting lists the newest five with reply links,
Quotes out counts live sent and viewed quotes whose valid-until has not
passed, New leads counts leads still in the New stage, and Active clients
counts clients that are not archived.

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
Email card; see [Mail](#mail) and [Replying](#replying) for composing messages.
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
phone numbers beginning with `+`. The leads CSV includes website inquiry
answers, consent, reference, and attribution (inside JSON metadata).

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
client contact facts stay intact; conversion sets their pipeline stage to Won
and preserves [AI opt-outs](#ai-assistance). Their timeline records Returned as a lead from
the source, with the campaign in the event metadata. Multiple historical
leads can link to the same client; conversion never merges two clients.
Without a match, conversion creates a client with the lead's facts,
including its exact source and campaign, and copies people and history.
Only clients created by conversion show Started as a lead.
Both paths transfer the lead's tasks, drafts, linked conversations, and remembered
email identities to the client, then link forward and freeze the lead read-only,
with no reverse path.

Fit labels and bar colors use the supplied fit band; the CRM does not
derive a band from the numeric score. Edit lets you enter these fields
manually and add another person in the blank People fields.

Website inquiries now arrive directly in Leads. Open a lead to read its
inquiry and optional travel details; unknown timing takes precedence over
previous dates. The Automations strip shows recent integration activity.
In Settings → Automations, manage credentials and the n8n subscription,
and review machine events and delivery results. The website form and external
n8n/Panda AI workflows are configured separately; see the
[website intake contract](docs/leads-intake.md) for setup, delivery behavior,
and the allowed automation actions.

## Mail

Email only, from `info@sherpaholidays.com` (fixed to `MAILBOX_ADDRESS`,
default `info@sherpaholidays.com`, with no additional accepted mailboxes). The CRM
reads the Microsoft 365 mailbox through Microsoft Graph with delegated
OAuth (the captain's own mailbox only; no tenant-wide grant). It keeps
only messages with an exact parsed mailbox address
in From, To, Cc, Bcc, Delivered-To, or X-Original-To; a message
naming the mailbox anywhere else (Reply-To, a list header) is not kept. Personal
mail is skipped without storing it, before any attachment bytes are fetched. This release reads
received and sent history; see [Replying](#replying) for composing and
sending from CRM. [AI assistance](#ai-assistance) can prepare a draft for review.

Setup (captain, about 10 minutes): register the CRM as a Microsoft
application with the delegated mail scopes, add the redirect URI, paste the
client id, tenant id, and secret into `.env.app`, then click Connect mailbox
in Settings → Mailbox → Test connection. The grant is only stored when
Microsoft confirms it belongs to `MAILBOX_ADDRESS`; approving as another
account is refused by name. Full steps live in
[Microsoft 365 mailbox](docs/operations.md#microsoft-365-mailbox).
Reconnecting replaces the grant; if access is revoked, sync records the
error and Settings offers Reconnect mailbox instead of failing silently.
Production encryption keys must be configured and preserved; see
[Secrets inventory](docs/operations.md#secrets-inventory).
Production sync runs every 5 minutes (`Mail::SyncJob` in `config/recurring.yml`) over
every mail folder, child folders included (Microsoft 365 has no All Mail
equivalent, and a server-side rule can file mail so it never touches the Inbox);
Deleted Items, Junk Email, Drafts, Outbox, and Conversation History are left out.
The folder list is re-read each run, so a folder created in Outlook is watched
without a reconnect, primed from now like a first connect; its past mail stays
for Import history. One
folder's failure is recorded against that folder and never stops the rest of the
run. If Microsoft expires a folder's sync token, the folder is re-primed and the
window since its last successful sync is re-read, so the gap is filled rather
than dropped - up to 24 hours. A longer outage than that is reported on the
Settings mailbox card, naming the date to import from, instead of the app
quietly opening months of mail: sync resumes from now and the depth of the
catch-up stays the captain's choice through Import history, with a preview.
That import brings back mail naming the mailbox in From, To, Cc or Bcc; mail
that reached it only as a hidden copy is not recovered that way, because the
backfill judges from a folder listing that carries no delivery header, and the
notice says so rather than promising a completeness it cannot deliver. Sync is incremental by per-folder delta link, threaded on
the Graph conversation id with a
Message-ID/In-Reply-To/References fallback. Read-only Graph access: only
GET requests, never moves, deletes, or flags server mail. Categories
arrive as an initial read-only label snapshot on each message; later
server-side label changes are not refreshed. A first connect primes the
delta links without ingesting anything, so ongoing sync starts from now
and past mail stays for Import history. Microsoft reports read-state
toggles, flags, and moves as changes too, so sync only takes mail received
since a folder was first watched: touching or filing away older mail never
brings it in behind the depth chosen in Import history.

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
There is no attachment-count cap. On import, files over 25 MB are skipped with a visible
message notice. Before any blob is created or uploaded, filenames, content types,
and PDF titles are screened for passport, visa, insurance, identity/ID,
date-of-birth, and scan documents. Flagged attachments are held, never filed
as ordinary attachments. On import, the bytes wait in a short-lived holding
area (`DocumentHolding`, Active Storage on the same private bucket, expiring
24 hours after ingestion and swept hourly in production) purely so the captain
can hand the file to PerfectBook; the timeline shows only a placeholder with filename,
size, type, and "held: send to PerfectBook", with no download link anywhere.
From the placeholder, or a still-stored ordinary attachment the captain flags,
**Send to PerfectBook** asks for the booking, traveler, and document type, uploads the bytes to PerfectBook's traveler-document endpoint through
`PerfectBook::Client` (multipart, idempotent on a stable upload id per CRM
file), then deletes every CRM copy, records an activity event with the
PerfectBook response, and refreshes that booking's mirror. Unclaimed holdings
become unavailable for hand-off at expiry; the next successful sweep deletes
their bytes and marks their placeholders expired. Failed storage deletions keep
retry references, so storage outages can delay physical deletion beyond expiry.
Failed ingestion uploads also retain cleanup references for the sweep (see
`Mail::Ingester.prepare` for the transaction boundary). Files over 10 MB
stay metadata-only placeholders because PerfectBook refuses larger uploads.
PDF metadata is parsed in memory; unreadable or encrypted PDFs
are also held. PDF titles are not persisted. Attached emails are screened
recursively: sensitive enclosures become held placeholders, safe enclosures remain
available, and an enclosing .eml containing a sensitive file is never uploaded as
an ordinary attachment. Held documents
appear in Triage even on linked conversations.

Send, Save draft, and recovery after a send validation error use the same
screening. A refused upload shows "Sensitive documents live in PerfectBook -
attach it there" and is never persisted; an attached email containing any
held enclosure is refused in full. Send stops for correction, while draft
saving retains the text and allowed attachments.

Every stored ordinary attachment still offers **Remove from CRM, collect in
PerfectBook** if the captain identifies a sensitive file that screening missed.
This deletes its stored file and removes every message or draft attachment
sharing that file, records an activity event, and leaves a follow-up note.
Storage failures preserve the reference and triage retry path. Only the
explicit **Send to PerfectBook** action uploads bytes to PerfectBook; neither
holding nor removing a file changes the mailbox.

Settings → Import history backfills past mail: all, since a date, or last
N months (no 90-day cap), as requested by the captain. The backfill walks the
same folders as live sync: every mail folder, child folders included, because
archived and filed mail is exactly what needs converting. Deleted Items, Junk
Email, Drafts, Outbox, and Conversation History are left out, children and all.
Preview scans the whole selected range in a background job, paging each folder
by received date with a resumable cursor.
It matches on the four recipient fields a folder listing returns
(From, To, Cc, Bcc) and opens only the messages that match, so no personal
message body is ever fetched;
Microsoft documents the message headers as retrievable only when getting a
single message, so a hidden-Bcc arrival that names the mailbox purely in a
delivery header is picked up by live sync, which applies the full six-header
check, rather than by the backfill. Progress and failures are visible;
commit is available only after the preview completes. Preview and import
persist the history cursor, so a resume continues where it stopped even if
earlier mail vanished. Because Graph promises no order among messages sharing a
received timestamp, a resume replays that whole second and dedupes on the
provider message id rather than risk dropping mail; preview and import both
count each message once, so a replay never counts twice. Import progress counts
the same in-scope messages as preview. Microsoft Graph throttling
(429) is waited out for a bounded number of Retry-After delays instead of
failing the run. Preview counts both inbound and
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

## AI assistance

Approval-only help on every thread: reply drafts, three-bullet summaries,
and suggested next actions. On unlinked threads, Classify with AI adds a
category, one-line reason, and suggested lead source to the triage card;
the captain still chooses link, create, or ignore. Link a client, lead, or
organization before accepting a suggested task. Acceptance creates only the
displayed proposal; if it has changed, review the current one. New mail
clears summaries, suggestions, and classifications; tap again to regenerate.
Nothing sends automatically; prices, availability promises, and legal or
refund language stay human. Thinking orbs show composing for drafts and
summaries, shaping for triage and suggestions. Plain fallbacks keep manual
work available when AI is off or fails.

AI assistance is on by default. In Settings → AI assistance, enter an
OpenAI-compatible base URL (OpenAI or OpenRouter), model name, provider key,
and short voice guide (templates are the style examples). Without a key,
threads show "Add a provider key in Settings to enable drafts".
Drafts appear in an editable dashed-edge block. Use this draft replaces the
body in the [reply box](#replying), opening it on phones, for editing and
review before Send. Copy draft lets the captain paste the text into his mail app.
Leaving the key blank when
saving preserves the saved key. For encrypted key storage and recovery, see
the [Secrets inventory](docs/operations.md#secrets-inventory).

The daily cost cap blocks new calls when recorded estimated spend reaches it;
zero disables the cap. Estimates use the fixed token rates in
`Ai::Client.estimate_cost`, not the selected model's actual billing rates,
and concurrent calls can exceed the cap. The per-minute limit paces bursts.
Turn off Enable AI assistance to block new calls (kill switch); calls already
sent to the provider are not cancelled. To exclude one record, tick Opt out
of AI assistance on that client, lead, or organization. This prevents new
generation for linked threads; it does not erase cached results or call logs.
Lead conversion preserves an opt-out on the destination client.

Prompts live in `config/ai_prompts.yml` under version control; the version is
logged on every call. Attempts reaching `Ai::Client.chat` are logged to
`ai_calls` (purpose, prompt version, model, token counts, cost estimate,
latency, status, redacted request and response) and pruned after 90 days
(`Ai::PruneCallsJob`). Requests blocked by the controller guard and cached
summary reads do not create call logs. Costs are stored as integer micro-cents
and summed before applying the daily cap. Only message text and CRM facts
reach the provider - never attachments, document bytes, or PDF titles. The
shared `Ai::Scrub` filter redacts recognized passport numbers, dates of birth,
and card-number patterns before sending and from returned text. This
application does not configure or guarantee provider-side zero retention;
retention depends on the chosen provider and account settings.

## Production shape

The Docker image is built by GitHub Actions and published to
`ghcr.io/samsherpadev/perfectcrm` after all required CI checks pass on a
`main` push. The server pulls it with `deploy/deploy.sh` and never builds. See
[docs/operations.md](docs/operations.md) for the deploy checklist, the
secrets inventory, backups, and the restore drill. Production credential and
bucket templates are in `.env.app.example` and `.env.litestream.example`;
backup cron variables are documented in the runbook.
