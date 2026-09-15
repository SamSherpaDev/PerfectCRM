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
  FTS tables because `schema.rb` does not dump virtual tables. It does not
  repopulate existing records; `sync_fts!` indexes each record.
- `TaggedRecord` validates pending tags before saving and assigns them in
  `after_save`; assigning through-tags before the parent saves trips
  Tagging uniqueness.
- Pipeline usage and integration points: see README.md, "Pipeline".
- System-test Chrome here needs nix NSS *and* NSPR libs on `LD_LIBRARY_PATH`
  (e.g. `nixpkgs#nss` + `nixpkgs#nspr` `.../lib`), plus an explicit
  `resize_to(1400, 900)` in desktop tests; check driver startup output if
  `chromedriver` cannot start.
- PerfectBook link: `PerfectBook::Client` (`lib/perfectbook/`) + mirror tables
  (`app/models/perfectbook/`) + `config/recurring.yml` jobs; contract in
  README.md, "PerfectBook connection". Mirrors only, never money truth.
- Mail inbound: `Conversation`/`Message`/`EmailIdentity` + `Mail::SyncJob`
  (5 min, read-only IMAP over `[Gmail]/All Mail`) + `Mail::ImportJob`;
  contract in README.md, "Mail". Keep-only-info@ rule lives in
  `Mail.keeps?`; inside `module Mail` always write `::Message` and
  `::Conversation` because `Mail::Message` is the mail gem.
- Views cannot name the `Template` model bare: the
  constant resolves to `ActionView::Template`. Expose what views need
  through helpers with explicit `::Template` references instead.
- Today and follow-ups: see README.md, "Today and follow-ups"; `Task`
  rules live in the model, the landing queries in `Today::Summary`,
  automatic proposals in `Tasks::Automatic` (idempotent per booking),
  and the digest in `TodayDigestJob` + `CaptainDigestMailer`.
