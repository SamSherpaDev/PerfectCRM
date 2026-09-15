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
- Appearance rule: the Paper/Night choice applies instantly via its own
  auto-submitting form + Stimulus controller (`appearance_controller.js`),
  surviving Turbo navigation — never gate it behind a separate Save.
- Google sign-in allowlist `ALLOWED_GOOGLE_EMAILS` (default
  `info@sherpaholidays.com`); `/up` is the only public route.
- System-test Chrome here needs nix NSS libs on `LD_LIBRARY_PATH`; see the
  failing-driver notes if `chromedriver` cannot start.
