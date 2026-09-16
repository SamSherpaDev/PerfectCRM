# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## PerfectCRM notes

- Sibling of PerfectBook (`SamSherpaDev/BK-app`): same stack (Rails 8.1 +
  Hotwire + Tailwind v4, SQLite primary/cache/queue, Solid Queue in Puma,
  Active Storage on R2), same VPS and deploy shape. PerfectBook stays the
  system of record for bookings, invoices, and money; the CRM owns people,
  conversations, quotes, tasks, and the pipeline. Money-free: no ledger here.
- `docs/DESIGN.md` is the visual contract (PerfectCRM's own Washi contract,
  approved 2026-09-14; Open Design format, captain's decisions in section 12).
  `docs/DESIGN-SYNC.md` explains what is shared with PerfectBook and how it
  syncs. Do not invent a separate visual identity.
- CRM-only kit lives in `app/assets/tailwind/application.css` (CRM layer) +
  shared partials; preview every component at `/design` (signed-in only).
  Rail order: Today, Inbox, Leads, Clients, Pipeline, Quotes, Templates,
  Settings; phone tab bar: Today, Inbox, Leads, Clients, More.
- Today's counts strip carries six `.stat` tiles, two rows of three on
  desktop. `docs/DESIGN.md` section 5 still reads "four equal tiles" from
  the four-tile era.
- Timezone `America/Los_Angeles` (`config/application.rb`).
- Leads convert to clients one way only, by the captain; no reverse action,
  by hand or automation (DESIGN.md 4.11).
- Appearance behavior and authentication policy: see README.md, "Navigation"
  and "Google sign-in". Preserve instant appearance changes.
- Plain `bin/rails server` serves the prebuilt `app/assets/builds/tailwind.css`;
  rebuild with `bin/rails tailwindcss:build` after CSS/view-class changes
  (`bin/dev` watches, plain server does not).

- Client and lead usage: see README.md, "Clients" and "Leads"; conversion
  lives in `Lead#convert_to_client!`, person ownership in `Person`, and
  nested email reassignment in `NestedPeople`.
- Search uses the models' `*.search` APIs; `ensure_fts!` recreates missing
  FTS tables. It does not repopulate existing records; `sync_fts!` indexes
  each record.
- `TaggedRecord` validates pending tags before saving and assigns them in
  `after_save`; assigning through-tags before the parent saves trips
  Tagging uniqueness.
- Pipeline usage and integration points: see README.md, "Pipeline".
- System-test Chrome here needs nix NSS *and* NSPR libs on `LD_LIBRARY_PATH`
  (e.g. `nixpkgs#nss` + `nixpkgs#nspr` `.../lib`), plus an explicit
  `resize_to(1400, 900)` in desktop tests; check driver startup output if
  `chromedriver` cannot start. Headless Chrome answers `(hover: hover)` with
  false and Tailwind v4 gates every `hover:` utility behind that query, so the
  kit's 1px hover lift never shows in a headless check; verify `:focus-visible`
  instead. `bin/rails test:system` also flakes when run in parallel; use
  `PARALLEL_WORKERS=1` before believing a system-suite failure.
- PerfectBook link: `PerfectBook::Client` (`lib/perfectbook/`) + mirror tables
  (`app/models/perfectbook/`) + `config/recurring.yml` jobs; contract in
  README.md, "PerfectBook connection". Mirrors only, never money truth.
  Document hand-off and retention policy: README.md, "Mail"; ingestion
  transaction invariant: `Mail::Ingester.prepare`.
- Mail inbound: `Conversation`/`Message`/`EmailIdentity` + `Mail::SyncJob`
  (5 min, read-only Microsoft Graph delta over every mail folder) +
  `Mail::ImportJob`; contract in README.md, "Mail". Delegated OAuth only
  (refresh token encrypted on `Setting`, `Mail::GraphAuth`); sync takes only
  mail received since the first connect (`Setting#mailbox_watched_since`). Keep-only-info@ rule lives in
  `Mail.keeps?`; inside `module Mail` always write `::Message` and
  `::Conversation` because `Mail::Message` is the mail gem.
- Outbound email: see README.md, "Replying"; recipient context is shared
  through `TemplateContext.resolve_recipient` for reply and group rendering.
- Views cannot name the `Template` model bare: the
  constant resolves to `ActionView::Template`. Expose what views need
  through helpers with explicit `::Template` references instead.
- Today and follow-ups: see README.md, "Today and follow-ups"; `Task`
  rules live in the model, the landing queries in `Today::Summary`,
  automatic proposals in `Tasks::Automatic` (idempotent per booking),
  and the digest in `TodayDigestJob` + `CaptainDigestMailer`.
- Website leads intake: public endpoints under `app/controllers/api/v1/leads/`
  (intake, details, verdict), contract in `docs/leads-intake.md`; automation
  settings on the Settings "Automations" card; `Leads` service module holds
  the relay HMAC, source, scoring, and rate-limit rules.
- AI assistance: see README.md, "AI assistance"; `Ai::Client` owns provider
  calls, `Ai::Scrub` the shared text boundary, and `Ai::Guard` eligibility.
  Composer insertion lives in `ai_assist_controller.js`; the thread panel
  currently owns `data-assist`.
- Quotes: see README.md, "Quotes". Builder reads mirrors through
  `PerfectBook::Catalog` (never the API from views); sending goes through
  `QuoteMailer` plus `QuotePdf`; the public accept page is
  `PublicQuotesController` (`/q/:token`, logged in `QuoteView`).
- Demo data: see `docs/getting-started.md`, "Demo data", for loading,
  cleanup, and ownership rules; implementation is `db/seeds/demo_seed.rb`.
- A partial's first-line `<%# locals: (...) %>` is parsed as strict locals:
  keep it pure Ruby on one line and put prose in a separate comment.
