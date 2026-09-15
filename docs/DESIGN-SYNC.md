# DESIGN-SYNC: the shared design package between PerfectBook and PerfectCRM

> Proposed shared package, 2026-09-14. Sections 1-5 describe the intended extraction and sync workflow, not installed tooling.

**Current implementation:** shared tokens and the CRM component layer coexist in `app/assets/tailwind/application.css`; drawings live in `app/views/shared/_sketches.html.erb`, their helper in `app/helpers/application_helper.rb`, and icons in `app/views/shared/_icon.html.erb`. There is no `design/` package, `config/design.yml`, export/sync command, version display, or package drift check yet. Edit the current sources in this repository. The proposed paths and checks below apply after extraction. [DESIGN.md](DESIGN.md) owns the visual contract; [README.md](../README.md) owns current product usage.

## 1. Why a package and not a copy

PerfectBook (`SamSherpaDev/BK-app`) and PerfectCRM (`SamSherpaDev/PerfectCRM`) are separate Rails apps with separate databases, deployed side by side on the same server. The captain asked that the CRM look like PerfectBook's sibling. Siblings drift when their shared parts are copied by hand and then edited in one place. The rule here is: **the shared parts are one set of files, PerfectBook is their home, and the CRM vendors them at a pinned version.** A change to a shared file happens in PerfectBook and is pulled into the CRM; a change to a CRM-only file happens in the CRM and never flows back.

The package is deliberately small. It is not a gem, not an npm package, not a git submodule (submodules are painful in a one-person shop). It is a directory that a script copies, with a version stamp that says which PerfectBook commit it came from.

## 2. What is in the package (copied verbatim)

The proposed extraction sources are listed below. Once vendored, shared package files must be changed in PerfectBook first. Source line numbers refer to the design proposal snapshot and are not a live index.

| Package path (in both repos) | PerfectBook source today | What it carries |
|------|------|------|
| `design/tokens.css` | the `@layer base { :root … html[data-scheme="night"] … }` block of `app/assets/tailwind/application.css` (lines 44 to 135) | every `--pb-*` scheme token for Paper and Night, grain, drawn rules, chevron |
| `design/theme.css` | the `@theme` and `@theme inline` blocks (lines 137 to 193) | fonts, fixed brand colours, radii, Tailwind utility mapping (`bg-paper`, `text-ink-3`, `shadow-raise`, …) |
| `design/components.css` | the `@layer components` block and the `@utility` blocks (lines 229 to 757) except the PerfectBook-specific `.stepper`/`.steps` styles, which move to PerfectBook's own file | typography classes, cards, captions, buttons, forms, segment, tabs, tables, badges, flash, callouts, facts, empty states, sketch classes, page header, rail, bars, links, page structure |
| `design/motion.css` | the keyframes, entrance rules, reduced-motion and print blocks (lines 759 to 803) | the three motion moments and their removal |
| `design/fonts/` | `app/assets/fonts/gelasio-*.woff2`, `montserrat-*.woff2` and the `@font-face` rules | the two faces |
| `design/sketches/shared.svg.erb` | `app/views/shared/_sketches.html.erb` symbols `sk-rule`, `sk-ridge`, `sk-river`, `sk-wheel`, `sk-enso`, `sk-mark` (and `sk-stupa`, `sk-teahouse`, which the CRM keeps but does not place) | the shared drawings |
| `design/icons.yml` | the `paths` hash in `app/views/shared/_icon.html.erb` | the 24-box line icons |
| `design/partials/` | `shared/_page_header`, `_empty_state`, `_stat`, `_flash`, `_icon`, `_logo` (logo takes the mark name and tile as locals), `_nav` is not shared | the partials that draw the vocabulary |
| `design/helpers.rb` | `ApplicationHelper#badge`, `#status_badge`, `#card_caption`, `#sketch`, `#tab_link`, `#nav_link`, `SKETCH_VIEWBOXES` (extended by the CRM, see below) | the helper API |
| `design/DESIGN.md` | PerfectBook `docs/DESIGN.md` | the parent contract; the CRM's `docs/DESIGN.md` refers to it and never restates sections 1 to 8 |
| `design/VERSION` | new | `perfectbook <sha> <date>` of the copy |

The first cut of this package is a refactor inside PerfectBook: split `application.css` into the four files above and `@import` them, move the sketch symbols and icon paths into the package paths, and add `bin/design-export` that writes the package directory. PerfectBook keeps working exactly as before; nothing visible changes. That refactor remains a prerequisite for package syncing; the CRM shell and kit already use the current source locations above.

## 3. What the CRM owns (never synced back)

| CRM path | Contents |
|------|------|
| `app/assets/tailwind/crm.css` | the CRM-only classes from `DESIGN.md` Appendix C: `.unread`, `.mark-inline`, timeline (`.timeline`, `.ev` incl. `.ev.auto`, `.msg`, `.stream`), reply box and chips, `.draft`, board, `.board-groups` and `.kcard`, `.tabbar`, docked reply, `.sheet`, `.stage-row`, `.sticky-send`, `.rowlist`, `.setting`, `.toggle`, `.dep`, `.src`, `.fit` |
| `app/views/shared/_sketches_crm.html.erb` | `sk-everest`, `sk-bridge`, `sk-pass`, `sk-cairn`, `sk-stream`, `sk-mark-a` (the chosen mark) |
| `app/helpers/crm_sketches.rb` | extends `SKETCH_VIEWBOXES` with the CRM names; `sketch(:everest)` uses `xMaxYMax meet`, `:stream` uses `none` |
| `app/views/shared/_nav.html.erb`, `_tabbar.html.erb` | the eight rail items and the five bottom-bar items |
| `app/views/layouts/application.html.erb` | the shell: rail on desktop, top bar plus bottom bar on the phone, docked areas |
| `public/icon.svg`, `icon.png`, `apple-touch-icon.png`, `favicon.ico` | the CRM mark on the ink tile |
| `docs/DESIGN.md` | the approved CRM contract, sections 2.2, 4, 7, 10, 12 are CRM-specific |
| `docs/DESIGN-SYNC.md` | this file |
| `config/design.yml` (proposed) | Configuration derived from the visual decisions owned by `DESIGN.md`; lead data remains owned by the model, with usage in README.md |
| `design/icons_crm.yml` | the CRM-only icons: lead, bolt, globe, ads, robot, arrow-right |
| `app/javascript/thinking_orbs.js`, `app/javascript/controllers/orb_controller.js` | the thinking-orbs port (MIT, Jakub Antalik) and its Stimulus mount; CRM-owned until PerfectBook has something to think about, then promoted into the package |

After extraction, the proposed CRM `application.css` would be: `@import "tailwindcss"; @import "./design/tokens.css"; @import "./design/theme.css"; @import "./design/components.css"; @import "./design/motion.css"; @import "./crm.css";`. The proposed layout would render `shared/sketches` (package) and `shared/sketches_crm` (own) once.

## 4. How a change propagates

**A shared change (tokens, a component, a shared drawing, the type scale):**

1. Make it in PerfectBook, in the package path, with its usual review and the contrast audit (PerfectBook `DESIGN.md` 9.10 is the model).
2. Bump `design/VERSION` in PerfectBook's `bin/design-export` output (it stamps the commit).
3. In the CRM, run `bin/design-sync <perfectbook-checkout-or-tag>`: it copies `design/` from that PerfectBook commit, overwrites the CRM's `design/` directory, writes `design/VERSION`, and fails if any file outside `design/` in the CRM references a class or token that no longer exists (a grep against the removed names).
4. Open a CRM PR titled "design: sync to perfectbook <sha>" with only that directory changed plus any call-site fixes. The screenshot check (below) runs on it.
5. Never edit `design/` in the CRM by hand. A CI check diffs the CRM's `design/` against the PerfectBook commit named in `VERSION` and fails on any difference.

**A CRM-only change (a new CRM drawing, a timeline rule, the phone shell):** made in the CRM's own files, reviewed there, no sync. If the change turns out to be wanted in PerfectBook too (for example the bottom tab bar), it is promoted: re-implemented in the package in PerfectBook, then synced back down and the CRM copy deleted.

**A contract change (a captain decision that changes the rules):** update PerfectBook `docs/DESIGN.md` if the rule is shared, or the CRM `docs/DESIGN.md` if it is CRM-only; the contract file travels with the code that implements it. `DESIGN-SYNC.md` lists which sections are which (section 3 above).

## 5. Keeping the siblings honest

- **Same version or one behind.** The CRM may lag PerfectBook by at most one package version; a sync PR is opened within a week of a PerfectBook package bump. `design/VERSION` is shown on the CRM Settings page under "PerfectBook" so the captain can see it.
- **Screenshot check.** Both repos keep a `test/design/` set of rendered screens (Today, Inbox thread, Client, Pipeline, Quote, Templates, Settings for the CRM; Dashboard, Expenses, Booking, Tax hub, Settings for PerfectBook) in Paper and Night at 1440 and 390px, produced by the same headless Chromium script. A sync PR must show the CRM screens unchanged except where the shared change intends them to move.
- **Contrast audit.** The runtime audit PerfectBook used in 9.10 (every text node against its composited background, both schemes) runs in both repos on every design PR; zero failures is the bar.
- **One place for the mark.** PerfectBook's `_logo` partial takes `mark:` and `tile:` locals so both apps render their mark with the same partial; only the symbol id and tile colours differ, and they come from `config/design.yml`.
- **Sibling rules are tests.** The CRM's `docs/DESIGN.md` section 10 "must never happen" list becomes a small lint: no `uppercase` utility, no second solid ochre button in a view, no `.card .card` with a shadow, no drawing element that is an ancestor of text, no colour hex outside `design/tokens.css` and `crm.css`.

## 6. The ecosystem is outside the package

Google Ads, Meta Ads, n8n and Panda AI touch the CRM only through its inbound and outbound API; none of them share the design package. Panda AI is the captain's own future app; if it adopts the Washi package, it does so the same way the CRM does (vendored at a pinned PerfectBook version) and this file gains a third column. Until then the CRM renders Panda AI as a named source with the robot icon and no logo.

## 7. Open questions for the ship crew

- Whether the package should also carry the Stimulus controllers that touch design (`sidebar`, `appearance`), or only CSS, SVG and partials. Recommendation: carry `appearance` (it is the scheme switch and must behave identically) and leave `sidebar` app-specific, since the CRM's phone shell differs.
- Whether PerfectBook adopts the CRM's bottom tab bar on the phone. It would improve PerfectBook's phone use too, but PerfectBook has 25 rail items and the bar holds five; a "More" screen would be needed. Not part of this scout.
