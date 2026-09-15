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
- `docs/DESIGN.md` is the visual contract (Washi, inherited from
  PerfectBook). Do not invent a separate visual identity.
- Timezone `America/Los_Angeles` (`config/application.rb`).
- Appearance behavior and authentication policy: see README.md, "Navigation"
  and "Google sign-in". Preserve instant appearance changes.
- Clients and leads: see README.md, "Clients" and "Leads". Leads convert
  one-way to clients (`Lead#convert_to_client!`); converted leads are
  read-only in the model. People belong to exactly one owner (client or
  lead); person emails are unique per owner so conversions can copy.
  Search is SQLite FTS5 (`clients_fts`, `organizations_fts`, `leads_fts`)
  with `*.search` APIs; FTS tables self-heal via `ensure_fts!` because
  `schema.rb` does not dump virtual tables.
- Tags on new records defer to `after_save` (`@pending_tag_list`); assigning
  `has_many :through` tags before the parent saves trips Tagging uniqueness.
- System-test Chrome here needs nix NSS libs on `LD_LIBRARY_PATH`; check
  driver startup output if `chromedriver` cannot start.
- PerfectBook link: `PerfectBook::Client` (`lib/perfectbook/`) + mirror tables
  (`app/models/perfectbook/`) + `config/recurring.yml` jobs; contract in
  README.md, "PerfectBook connection". Mirrors only, never money truth.
- Views cannot name the `Template` model bare: the
  constant resolves to `ActionView::Template`. Expose what views need
  through helpers with explicit `::Template` references instead.
