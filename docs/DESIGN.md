# Design System for PerfectCRM

> Category: Travel & Hospitality, internal client-communication app
> Sibling of PerfectBook. Same paper, ink, ochre seal and soft relief; its own mark, mountain, drawings and phone layout.

This file is the brand contract for PerfectCRM, the client relationship and communication hub of Sherpa Holidays, planned at perfectcrm.sherpaholidays.com. It is written in the Open Design format so that an implementation crew can build the app from it without the concept's author.

PerfectCRM is a **sibling of PerfectBook, not a twin**. The parent contract is PerfectBook's `docs/DESIGN.md` (sections 1 to 8 measure the public website, section 9 is the Washi token set). This file does not restate the website measurements. It restates the tokens the CRM commits to (so the file stands alone), then records what the CRM shares verbatim with PerfectBook, what it adds, and what it must never do. `DESIGN-SYNC.md` next to this file describes how the shared parts move between the two repositories.

Status: **approved for the build.** Round 1 (2026-09-14) approved with the leads condition; round 2 (same day) approved the Leads section, the lead page, the automation vocabulary and the thinking orbs: "Alright this all looks good, go ahead with this build" (section 12).

## 1. Visual theme and atmosphere

PerfectCRM is the app the captain answers clients from, mostly on his phone. It reads as PerfectBook's quieter sibling: the same cream paper with visible grain, the same warm ink, one ochre seal, soft relief on anything you can press, and thin ink drawings of the Himalaya. The difference is the subject. PerfectBook is about money and dates; the CRM is about conversations, so its signature surfaces are a stream (the river turned on its side, running down every client timeline) and a bridge (two banks, one line between them).

**Key characteristics:**

- Paper first (`#fcfaee`) with a Night scheme on the same tokens; Paper is the default, Night is a toggle in Settings, exactly as PerfectBook.
- One accent, the ochre seal, used for: the primary button, the active rail item, the brush underline on the active tab, the enso, and the CRM's own **unread mark** (a 8px seal square beside anything a client wrote last).
- Gelasio for page titles, thread titles, headline numbers and stage counts; Montserrat for everything else. Sentence case everywhere.
- Every page header carries the **Everest** drawing (Nuptse, the summit with its plume, Lhotse) where PerfectBook carries Ama Dablam. This is the one-glance difference between the two apps.
- **Leads and clients are two sections.** A lead is anyone who asked and has not booked; a client is anyone who has. A lead converts to a client once, by the captain, and never back. Leads carry a source, a campaign, and Panda AI's fit score; automated steps (n8n, Panda AI) show on the timeline with a bolt.
- The CRM mark is in the prayer-wheel family and reads as speech: **the wheel that speaks** (chosen by the captain over the two-wheels variant). It sits on an **ink tile with an ochre stroke**, so the two browser tabs (ochre tile for PerfectBook, ink tile for the CRM) never get mixed up.
- A caption under every card and table title; tabs with an icon, a sentence-case label and a count; badges that always carry a word.
- On the phone: a bottom tab bar, a reply box docked over the home indicator, a templates sheet, and a pipeline that becomes a stage list. All in thumb reach at 390px.

## 2. Colour palette and roles

### 2.1 Scheme tokens (copied verbatim from PerfectBook)

The CRM uses PerfectBook's token names and values without change. They are listed here so this file stands alone; the source of truth for the values is the shared design package (see `DESIGN-SYNC.md`).

| Token | Paper (light) | Night (dark) | Role |
|------|---------------|--------------|------|
| `--paper` | `#fcfaee` | `#14110e` | Page |
| `--paper-2` | `#fffdf6` | `#1a1613` | Raised surface: cards, tiles, inbound message cards, kanban cards |
| `--paper-3` | `#f7f0e3` | `#100e0c` | Pressed well: inputs, the reply box, outbound message cards, segment groove |
| `--band` | `#f0ecdc` | `#211c18` | Quiet band: notes on the timeline, tag chips, table header rows |
| `--ink` | `#14110e` | `#fcfaee` | Headlines, names, money |
| `--ink-2` | `#3d3226` | `rgba(252,250,238,.85)` | Body, message text |
| `--ink-3` | `#5a5550` | `rgba(252,250,238,.60)` | Labels, captions, meta, timestamps |
| `--ink-4` | `#8b8680` | `rgba(252,250,238,.38)` | Placeholders, disabled, inactive tab icons, the "not yet spoken" stone |
| `--rule` / `--rule-2` | `rgba(20,17,14,.10)` / `.06` | `rgba(252,250,238,.08)` / `.05` | Hairlines |
| `--neutral-tint` | `rgba(20,17,14,.07)` | `rgba(252,250,238,.08)` | Neutral badge fill, tab count fill |
| `--seal` | `#c96f1a` | `#e2963f` | Marks: unread square, active icon, enso, brush underline, bar fills, large numbers |
| `--seal-text` | `#9a520f` | `#e2963f` | Orange text under 18px: eyebrows, tab counts, brand badges, "Open client" links |
| `--seal-tint` | `rgba(201,111,26,.10)` | `rgba(226,150,63,.12)` | Selected row, brand badge fill, AI draft block |
| `--btn-primary` | `#a85a12` on `#fcfaee` text | `#c96f1a` on `#14110e` text | The one solid button per view; hover `#8f4c0e` / `#e2963f` |
| `--good` / `-mark` / `-tint` | `#3f6a2a` / `#8fbf6a` / `rgba(79,122,54,.12)` | `#8fbf6a` / same / `rgba(143,191,106,.14)` | Won, done, on file, sent |
| `--warn` / `-mark` / `-tint` | `#8a6412` / `#e0b04a` / `rgba(224,176,74,.22)` | `#e0b04a` / same / `.14` | Nudged, due today, passport expiring |
| `--bad` / `-mark` / `-tint` | `#93362b` / `#e07160` / `rgba(224,113,96,.16)` | `#eb8a7f` / `#e07160` / `.14` | Errors, overdue |
| `--info` / `-mark` / `-tint` | `#2f5f82` / `#7fb2d9` / `rgba(127,178,217,.22)` | `#7fb2d9` / same / `.14` | New, post-trip, PerfectBook events |
| `--rail` / `--rail-active` | `#14110e` / `#1f1a16` | `#0f0d0b` / `#1a1613` | The ink rail, both schemes |
| `--sketch` / `--sketch-op` | `#3d3226` / `.9` | `#fcfaee` / `.62` | Every drawing |
| `--edge` | `rgba(20,17,14,.06)` | `rgba(252,250,238,.05)` | Hairline that keeps relief legible |
| Grain | PerfectBook's `--pb-grain` per scheme | same | Paper grain on the page; removed on print |

Fixed brand colours that never change with the scheme: cream `#fcfaee`, ochre `#c96f1a`, ochre deep `#a85a12`, ink `#14110e`.

### 2.2 Roles the CRM adds

| Role | Token used | Rule |
|------|-----------|------|
| Unread mark | `--seal` square 8px, radius 2px, `0 0 0 3px --seal-tint` halo | Beside any client, thread, task or kanban card where the client wrote last and there is no reply. Clears when a reply is sent. Never colour alone: the row also shows the client's name in `--ink` weight 500 and, in lists, an "Unread" badge or the bottom-bar count. |
| Stone colours (timeline) | inbound `--seal`; outbound `--ink-3`; note `--paper-2` with `--ink-4` ring; quote `--seal`; PerfectBook event `--info-mark` | The stone on the stream says who spoke. The event's meta line always names them too. |
| Stage tones | New `info`; Chatting `neutral`; Quoted `brand`; Nudged `warn`; Won `good`; Post-trip `info`; Lost `quiet` (transparent fill, `--ink-3` text, hairline ring) | One badge per stage, always with the word. The pipeline column head uses the same icon in `--seal`; Lost uses `--ink-4`. |
| Inbound vs outbound | inbound `--paper-2` raised; outbound `--paper-3` pressed, indented 40px | Relief tells the two apart at a glance in both schemes; the stone and the name confirm it. |
| AI draft | `--seal-tint` fill, `1px dashed rgba(201,111,26,.45)`, `--ink` text, a `--seal-text` tag "AI draft, yours to edit" | A dashed edge means "a machine wrote this". It becomes an ordinary pressed reply box the moment the captain edits it. |
| Automation event (timeline) | stone: `--paper-2` with a 2px `--info-mark` ring; body: transparent with `1px dashed --rule`; meta icon: bolt (n8n) or robot (Panda AI) | The second use of the dashed edge: something a machine did. The meta line names the machine ("Website form via n8n", "Panda AI"). |
| Source | `.src`: 14px `--ink-4` icon plus 12.5px `--ink-2` text; icons: megaphone (Google Ads, Meta Ads), globe (website form), mail (email), person (referral), pencil (manual) | Every lead shows where it came from, with the campaign name after a middle dot where an ad supplies one. |
| Fit | `.fit`: a 56px `.bar` (`bar-good` at 70 and above, `bar-warn` 40 to 69, `bar-bad` below 40) plus the word and the number ("Strong · 82", "Possible · 61", "Weak · 34"); "Scoring" as an info badge with the robot icon while Panda AI has not answered | Colour, word and number together; never the bar alone. |
| Automated | info badge with the bolt icon | On any row, card or setting whose last change was made by n8n. |

Contrast is unchanged from PerfectBook 9.1: every text token meets 4.5:1 on its surface; `--seal` and `--ink-4` are never used for text under 18px; badges on tinted fills use the deepened text shades PerfectBook shipped in its 9.10 audit.

## 3. Typography

Gelasio (metric-compatible with Georgia, self-hosted) and Montserrat (variable, self-hosted), the same files PerfectBook ships in `app/assets/fonts/`. Tabular numerals on money, counts and times.

| Role | Size / line | Weight | Face | Notes |
|------|-------------|--------|------|-------|
| Page title | 40px / 1.1 (32px on the phone) | 400 | Gelasio | `-0.015em` tracking |
| Thread title (client name in a thread) | 22px / 1.2 (20px phone) | 400 | Gelasio | `-0.01em` |
| Stat value | 32px / 1 (24px phone) | 400 | Gelasio | tabular |
| Stage count (phone stage list) | 22px / 1 | 400 | Gelasio | tabular |
| Quote total (summary card, docked bar) | 30px / 1 (22px docked) | 400 | Gelasio | tabular |
| Card title | 16px / 1.3 | 600 | Montserrat | |
| Body | 14.5px / 1.55 | 400 | Montserrat | |
| Message body (timeline) | 13.5px / 1.55 | 400 | Montserrat | max 56ch on desktop, full width on the phone |
| Table | 13.5px / 1.45 | 400, 500 on names | Montserrat | |
| Caption | 12.5px / 1.4 | 400, `--ink-3` | Montserrat | one line under every card and table title |
| Label | 12.5px / 1.3 | 500, `--ink-3` | Montserrat | |
| Eyebrow | 13px / 1.3 | 500, `--seal-text` | Montserrat | sentence case |
| Meta line (who, when) | 12px / 1.3 | 600 name in `--ink`, 400 time in `--ink-3` | Montserrat | |
| Badge | 12px / 1.5 | 500 | Montserrat | |
| Chip (template) | 12.5px / 1.3 | 500 | Montserrat | |
| Bottom tab label | 10.5px / 1 | 500 | Montserrat | |
| Hint | 12px / 1.5 | 400, `--ink-3` | Montserrat | |

Rules carried over: the serif is never bolded; uppercase is not used; Montserrat carries all controls, numbers and labels.

## 4. Components

Everything in PerfectBook's `docs/design-system.md` component list exists in the CRM with the same class names and behaviour: `.card`, `.card-header`, `.card-title`, `card_caption`, `.card-foot`, `.stat`, `.btn-primary`/`.btn-secondary`/`.btn-ghost`/`.btn-danger`, `.input`/`.select`/`.textarea`/`.checkbox`, `.segment`, `.tabs`/`tab_link`, `.table-wrap`/`.table`/`.table-compact`, `badge`/`status_badge`, `.bar`, `.callout-*`, `.facts`, `shared/_empty_state`, `shared/_stat`, `shared/_page_header`, `shared/_flash`. This section describes only what the CRM adds or specialises.

### 4.1 Shell

- **Rail (desktop).** PerfectBook's 76px ink rail, expanding to 264px on hover or focus, with the same `.nav-link` styling and the seal square beside the active item. Eight items: Today, Inbox (with an ochre count badge when replies are waiting), Leads, Clients, Pipeline, Quotes, Templates, Settings. The logo tile is the CRM mark on an ink tile (`#14110e`, ochre stroke, `inset 0 0 0 1px rgba(226,150,63,.35)`), 36px, radius 10px.
- **Bottom tab bar (phone only, under 750px).** Five items: Today, Inbox (with count), Leads, Clients, More (Pipeline, Quotes, Templates, Settings; More is lit when any of those is open). 20px icons, 10.5px labels, a 3px seal bar above the active item, `--paper-2` at 94 percent with backdrop blur, safe-area inset padding. Replaces PerfectBook's drawer; the top bar keeps only the mark, the wordmark and the avatar. The tab bar hides on the thread view and the quote builder, where the docked reply box or the docked total takes its place.
- **Browser tab.** Favicon is the CRM mark on the ink tile at 16, 32, 180 and 512px; `theme-color` `#fcfaee` for Paper and `#14110e` for Night.

### 4.2 Page header

`shared/_page_header` unchanged in shape (eyebrow, Gelasio title, subtitle, actions bottom-right, at least 160px tall on desktop), with `sketch :everest` in place of `:ridge`. The drawing stays top-right, draws itself on load, and shrinks to 200px wide on the phone without covering text. One `.btn-primary` per header; secondary actions are raised paper and hide on the phone when the primary covers the same job.

### 4.3 Lists and rows

- `.rowlist` is the CRM's list-in-a-card: 12px 24px rows separated by `--rule-2`, a name in `--ink` 500, a one-line secondary in `--ink-3` that truncates with an ellipsis, and a right-aligned meta column (time, badge, small button). Rows wrap on narrow widths so a button never crushes the name.
- `.unread` adds the unread mark at left (34px indent).
- Check rows (follow-ups) use a 18px pressed square (`.check`), `--good-mark` when done; done rows stay for the day with the name struck through in `--ink-3`.

### 4.4 Inbox and the timeline

- **Two panes on desktop:** a 300px client list card (search well on top, rows with name, time, last line, stage badge and trip) and the thread card. On the phone one pane shows at a time; the thread has a back link to the list.
- **Filter tabs above both panes:** Waiting on you, Waiting on them, Everyone, each with a count. "Waiting on you" is the default and is where unread lives.
- **The stream.** `sketch :stream` (the river drawn vertically, two strokes) runs the full height of the timeline, 26px wide, 44px from the left edge of the card (12px on the phone). Each event is a `.ev` row: a stone (11px circle on the stream), a meta line (icon, name in `--ink` 600, time in `--ink-3`, optional badge), and a body.
- **Event bodies.** Inbound email: raised `--paper-2` card, radius 12px, 14px 16px padding, 13.5px text, first four lines then "Read the full email" in `--seal-text`. Outbound: pressed `--paper-3` card, indented 40px (20px phone). Note: `--band` with a 3px `--ink-4` left rule, radius 10px. Quote sent and PerfectBook events: transparent, `1px solid --rule`, contents in one row (badge, description, small link "Open in PerfectBook" with the external icon in `--seal`). Order is oldest at the top, newest at the bottom next to the reply box; on the phone the view opens scrolled to the newest.
- **Reply box.** Sits at the bottom of the thread card under a drawn rule (`--sk-line`). "Reply to Amara Okafor · Re: subject" line (hidden on the phone), a pressed `.textarea` (104px tall, 72px on the phone), then a tools row: template chips on the left (the three most-used templates plus "Draft a reply" with the sparkle icon), the `.btn-primary` Send on the right. On the phone the reply box is docked (`position: absolute; bottom: 0` inside the app shell) over the home indicator, on `--paper` with grain, a top hairline and a soft upward shadow; the chips scroll in one row without a visible scrollbar; Send is at least 44px tall and 92px wide.
- **Templates sheet (phone).** Tapping the sparkle chip opens a bottom sheet (`--paper-2`, radius 18px top, a 36px grab bar, backdrop `rgba(20,17,14,.28)`): a "Draft a reply" row on `--seal-tint`, the three most-used templates as 48px rows with name and first line, then "All templates". One tap fills the reply box and closes the sheet.
- **AI draft.** Appears inside the reply box area as the `.draft` block described in 2.2, with the tag "AI draft, yours to edit". Tools become Edit and Try again; Send is unchanged. Nothing sends until Send is pressed; there is no auto-send setting.
- **Template chips.** `.chip`: pill, `--paper-2`, `--raise-sm`, 12.5px 500 text, a 13px `--seal` icon, 32px tall, 8px gaps. Tag chips (`.chip-tag`) are flat on `--band`.

### 4.5 Client page

Header with back link, eyebrow "Client · {stage}", the client's name as title, a one-sentence subtitle (where they are, what trip, who referred them). Tabs: Overview, Timeline, People, Quotes, Bookings, Notes, each with a count. Cards: Facts (`.facts` grid plus tag chips), Latest (last message with a Reply button and the next promise), People (table with passport status badges), Quotes (table with status badges and money right-aligned), Bookings in PerfectBook (table labelled "Read only", the booking reference is the deep link, empty state with enso and the cairn), Notes (rowlist). Foot: the mani wall drawing with a one-line caption.

### 4.6 Pipeline

- **The trail.** Above the board, `bookings/_status_stepper`'s pattern: one drawn rule with seven dots, New, Chatting, Quoted, Nudged, Won, Post-trip, Lost; done stages in `--good-mark`, the selected stage as a 16px `--seal` dot with a tint halo. One caption line explains the reading order.
- **Groups over the board.** A label row on the same seven-column grid names the halves: "Leads" over New to Nudged, "Clients" over Won and Post-trip, "Off the path" over Lost, each on a drawn rule. Dropping a card on Won asks "Convert to client?"; once confirmed the card cannot be dragged back to a lead column.
- **Board (desktop).** Seven columns, `repeat(7, minmax(128px, 1fr))`, 12px gaps, inside a container that scrolls sideways only if narrower than 968px. Column head: icon in `--seal`, name 13.5px 600, count 12px `--ink-3`, a drawn rule below; a `col-sum` line ("$42,230 out") where money applies. Cards (`.kcard`): raised, radius 12px, 10px padding, name 13px 500, trip 12px `--ink-3` truncated, a bottom row with age of last message and money or guests; a 12px grip icon top-right; a 3px `--seal` left edge when the client is waiting on a reply (`.kcard.unread-k`). A dragged card leaves a dashed `--ink-4` ghost at its target. Counts and totals update on drop; nothing else animates.
- **Stage list (phone, recommended).** Seven `.stage-row`s: a 34px `--band` icon tile, name 14.5px 500, a one-line hint or the money out, the count in Gelasio 22px, a chevron. Tapping opens the stage's cards beneath it (the row goes pressed); moving a client is a menu on the card ("Move to Nudged"). The alternative the captain may pick is one stage at a time with a scrolling segment control; see section 12.

### 4.7 Quote builder

Two columns on desktop (`3fr 2fr`): left, "Trip and departure" (a `.select` fed by PerfectBook's catalog, then departure rows `.dep` as raised radio rows with date, seats left and catalog price; the chosen row goes pressed with a seal dot), "Lines" (compact table with quantity wells, each and total right-aligned, an Add line button in the header), "Note to the client" (textarea). Right, "Summary" (subtotal, deposit, balance due date, valid until, then the total in Gelasio 30px with "Total for 4 guests" as its label, Send quote and Preview as the client), "When they accept" (three checked lines). On the phone the columns stack, the summary's buttons hide, and a docked bar shows the total (Gelasio 22px, guests and dates beneath) with a 44px Send quote.

### 4.8 Templates

Tabs: Replies, Nudges, Post-trip, AI voice, with counts. Left, a compact table (template, first line, used count) ordered by use; the selected row sits on `--seal-tint`. Right, the editor: name well, body textarea, field chips (`{first_name}`, `{trip}`, `{departure_date}`, `{deposit_due}`, `{guide}`), Save template and History. The three most-used replies are the chips in every reply box; there is no separate setting. The AI voice tab holds the draft voice as an editable template.

### 4.9 Settings

`.page-narrow`. Appearance first with PerfectBook's `.segment` (Paper with the sun icon, Night with the moon), applied on selection. Then Mailbox, PerfectBook (the read link: host, token version, last refresh, counts; a Rotate token button), AI drafts ("Always show me the draft before it sends" on and disabled, Voice with Edit voice, "Suggest a nudge after N days"), Automations and sources (the inbound API token for n8n with its last call; "Panda AI qualifies new leads"; "Automations may move a lead between New, Chatting and Lost" with the hint "Quoted, Nudged and Won stay yours"; the source list), Notifications. Rows are `.setting`: name 14px 500, hint 12.5px `--ink-3`, a control on the right (`.toggle` 40 by 22px, seal when on; a small select; a small secondary button). Foot: the shared prayer wheel drawing, the one place the parent mark appears in the CRM.

### 4.10 Empty states

`shared/_empty_state` unchanged: an enso on every empty state and beside cleared good-toned zeros. Scenes by area: Today `:pass` ("Nothing waiting. Enjoy the quiet."), Inbox `:bridge`, Clients `:bridge` (foot of the client page too), Leads `:cairn`, Pipeline `:pass`, Quotes and Templates `:cairn`, Settings `:wheel`. The sign-in card shows `:bridge` with the shared `:ridge` behind it, so the family is visible before signing in.

### 4.11 Leads

The captain's round-1 condition, in his words: "There should be a leads section and a client section as well. All the leads can be converted to clients, but cannot be reveresed."

- **Two sections, one vocabulary.** Leads has its own rail item, bottom-bar item, page, tiles, tabs and table; it uses the same cards, captions, badges, stream and reply box as Clients. A lead's timeline is identical in shape to a client's.
- **Page.** Header (eyebrow, "Leads", a one-sentence subtitle, New lead primary, Sources secondary). Four tiles: New this week, With Panda AI (info tone), Strong fit unanswered (warn), Converted this season (good). Tabs: Open, Scoring, Converted, Lost, with counts. One table, best fit first: Lead (name, then party size and dates in `--ink-3`), Source (`.src`), Asked about (trip), Fit (`.fit`), Stage (stage badge), Last touch (right-aligned). The unread mark appears inline before the name where the lead wrote last.
- **Lead page.** Same shape as the client page with the lead's facts (source, campaign, fit and Panda AI's reason, asked-about trip, party, dates), the stream, quotes, notes, and one primary action, **Convert to client**, in the header once the stage is Won. A converted lead's page stays readable but read-only, with a line "Became a client on {date}" linking forward; the client page carries "started as a lead" in its facts. There is no reverse action anywhere in the interface, and no automation may perform one.
- **Conversion.** One button, one confirmation ("Convert {name} to a client? Their whole timeline moves with them. This cannot be undone."), then the client page opens. The stream gains a `q`-style outlined event "Converted to client". PerfectBook gets the booking task; n8n is told through the outbound webhook.
- **Stages.** New, Chatting, Quoted, Nudged and Lost are lead stages; Won and Post-trip are client stages. The pipeline board shows both halves under group labels (4.6). Lost is a lead stage that can step back to New; it is not a client.

### 4.12 Ecosystem readiness (ads, n8n, Panda AI)

The captain's words: "in the future I want to implement google ads/meta ads to PerfectCRM through n8n automation and so that leads come in, it gets sent to panda AI which is another web app that I am designing which qualifies leads, then through n8n back to PerfectCRM for status changes, etc.. you get the idea, it will be an entire ecosystem, so I want you to make sure to prepare for this."

What the design prepares, so that the ecosystem plugs in without a redesign:

- **Every lead has a source and a campaign.** Source is an enumeration the Settings page shows (Google Ads, Meta Ads, Website form, Email, Referral, Manual) and can grow; campaign is free text supplied by the ad platform. Both render through `.src`.
- **Fit is a first-class field**, not a note: a 0 to 100 score, a word band, and a one-line reason, all from Panda AI through n8n, shown in the table, the tiles and the stream. While unanswered the field shows "Scoring". Panda AI has no logo in the CRM until it exists; it is named in text with the robot icon.
- **Automation events are a timeline kind.** Anything n8n or Panda AI does lands on the stream as an `automation` event with the machine's name in the meta line, a bolt or robot icon, and the dashed edge. The captain can always tell what a machine did.
- **Automations have limits the UI states.** Settings lists what automations may do (create leads, score them, move between New, Chatting and Lost) and what stays manual (Quoted, Nudged, Won, Convert). These are the permissions the inbound API enforces.
- **The inbound API is visible.** Settings shows the token version, the last call and a Rotate token button, the same way the PerfectBook read link is shown. The Leads page's Automations card lists each automation with its last run and an Automated or Manual badge.
- **Outbound is symmetric.** When the captain changes a stage, sends a quote or converts a lead, n8n is told, so Panda AI and the ad platforms can learn from outcomes. Nothing in the UI changes for this; it is a design commitment the ship crew builds against.

### 4.13 Thinking orbs

Decided by the captain on 2026-09-14 ("yes to the orbs"). Wherever the CRM is thinking, a small dotted orb shows what kind of thinking, ported from the MIT library **thinking-orbs** by Jakub Antalik (`github.com/Jakubantalik/thinking-orbs`): plain 2D canvas arcs, no WebGL, no filters, identical in every browser. The geometry is the library's (its `ribbon` and `morph` modes with the shipped 64 and 20 presets, unchanged); the painter is Washi.

| | Composing | Shaping |
|--|--|--|
| Library state | `composing` (an undulating multi-band sash) | `shaping` (a dotted outline: circle, triangle, square) |
| Means | writing on the captain's behalf: a reply draft, a summary, a quote note | sorting or judging: Panda AI scoring a lead, triage of unknown senders into leads |
| 64px avatar | the composing block in the reply box while a draft is written; the templates sheet's AI row while it works | a lead page header while its first score is pending |
| 20px inline | beside "Writing a reply…" in a chip or meta line | inside the "Scoring" badge on the Leads table and beside the "With Panda AI" tile number |

- **Ink.** Ochre dots on paper (`rgb(201,111,26)`), cream dots on ink (`rgb(252,250,238)`). The library carries depth as grey; the CRM carries it as alpha on the one brand colour: `alpha = a × (1 − 0.8 × white)`, where `white` and `a` are the library's per-dot values. No grey dots anywhere. The scheme is read from the nearest `[data-scheme]` ancestor.
- **Sizes.** Exactly the two tuned presets, 64 and 20 CSS px, device-pixel-ratio capped at 2. They are separate designs, not a scale; nothing in between is used.
- **Rules.** One orb per surface, never two. The orb always sits beside a sentence saying what is happening and carries `role="img"` with an `aria-label` ("Composing…", "Shaping…", or a specific one such as "Panda AI is scoring this lead"). Never on a button. It exists only while something is genuinely in progress and is removed the instant the result lands; it is the CRM's only continuous motion.
- **Reduced motion.** `prefers-reduced-motion: reduce` renders the library's representative static frame (`t = 0.6`) in the same ink. Orbs pause when scrolled offscreen and when the tab is hidden; all instances share one clock.
- **Implementation.** A ~120-line vanilla port (`app/javascript/thinking_orbs.js`, MIT notice kept) with a Stimulus controller `orb` that takes `state` and `size` values and mounts on a `<canvas data-controller="orb">`. The React component is not used. See Appendix C for the port's contract.

## 5. Layout

- **Desktop.** Rail 76px; content gutters 48px (40px inside the concept's frames); `.page` max 1024px with 40px between sections; `.page-narrow` 672px. Page header at least 160px tall. Stat rows are four equal tiles. Inbox is `300px minmax(0,1fr)` with 24px gap. Card padding 24px; card headers 22px 24px 6px; captions 0 24px 12px.
- **Phone (390px, iPhone 14 size, up to 749px).** 16px gutters; page gap 24px; two stat tiles per row at 14px padding; every grid becomes one column; tabs scroll in one row; card padding 18px; tables scroll inside their card; `.foot-sketch` captions hide and the drawing shrinks to 220px. The bottom tab bar is 64px plus the safe-area inset; content gets 96px bottom padding (230px in a thread, to clear the docked reply box).
- **Tablet (750 to 989px).** PerfectBook's behaviour: rail becomes a drawer, two-column grids. The inbox shows the list and thread side by side from 900px.

Radii and sizes are PerfectBook's: card 12px, tile 16px, control and button 10px, badge and chip 999px, seal square 2px at 8px, buttons 38px (44px minimum on the phone for Send and sheet rows), inputs 40px, table rows 46px (40px compact), kanban card radius 12px, sheet radius 18px top.

## 6. Depth and relief

PerfectBook 9.2 applies unchanged: `--raise`, `--raise-sm`, `--press`, `--edge`, light from top-left, blur never over 16px, dark shadow never over 0.14 on paper, no relief inside relief (a card inside a card goes flat with a hairline), hover lifts 1px, press collapses to the well, focus is never conveyed by relief alone.

The CRM's one specialisation: **on the timeline, relief says who spoke.** Inbound cards are raised, outbound cards are pressed, notes are flat on the band, and system events (quotes, PerfectBook) are outlined. This is allowed inside the thread card because the thread card is the only raised surface there; the events themselves are the "flat with a hairline" exception made expressive. A kanban card is raised; a dragged card's ghost is flat and dashed.

## 7. Sketch library

Same line (1 to 1.2px), same colour (`--sketch`), same opacity per scheme (0.9 Paper, 0.62 Night), same rule: one drawing per surface, never behind text, removed on print. Symbols live in `shared/_sketches`; `sketch(name, class:)` draws one; `SKETCH_VIEWBOXES` lists the names. The captain kept five CRM drawings and dropped two (mani wall, confluence) in the round-1 review; the dropped ones are not shipped.

| Name | Viewbox | Shared or CRM | Where |
|------|---------|---------------|-------|
| `rule` | 0 0 720 6 | shared | table heads, card feet, the trail, the reply box rule |
| `river` | 0 0 720 40 | shared | between page sections |
| `enso` | 0 0 64 64 | shared | every empty state, cleared zeros |
| `wheel` | 0 0 120 150 | shared | Settings foot |
| `ridge` (Ama Dablam) | 0 0 600 150 | shared | sign-in card only, behind the bridge |
| `mark` (prayer wheel, PerfectBook) | 0 0 24 24 | shared, not used in the CRM shell | reference only |
| `everest` | 0 0 600 150 | CRM | every page header (`xMaxYMax meet`) |
| `bridge` | 0 0 300 150 | CRM | Inbox empty state, sign-in card, client page foot, client list empty state |
| `pass` | 0 0 300 150 | CRM | Today empty state, pipeline foot and empty state |
| `cairn` | 0 0 300 150 | CRM | Quote builder, Templates, Leads, the Bookings empty state |
| `stream` | 0 0 40 720, `preserveAspectRatio="none"` | CRM | the spine of every timeline |
| `mark-a` (the wheel that speaks) | 0 0 24 24 | CRM | logo tile, favicon, sign-in (chosen) |
| `mark-b` (two wheels) | 0 0 24 24 | CRM | not chosen; kept in the concept for the record, not shipped |

Budget per surface: the Everest ridge in the header and one river or scene lower down. The stream is structural, not decorative, and does not count against the budget. Required ensos are outside the budget. The exact SVG for every symbol is in Appendix A.

## 8. Motion

PerfectBook's three moments, unchanged: the ridge (here Everest) draws itself on page load (1.3s, `pb-draw`), the enso draws itself when rendered (0.9s), stat values settle in (0.5s, staggered 60ms). One CRM addition: **a stone lands**. A second, decided in round 2: the **thinking orbs** of 4.13, the only continuous motion, present only while a draft or a score is in progress. When a reply or note is sent, the new event fades and rises 3px onto the stream over 300ms (`pb-settle`), and the unread mark on that client clears. Hover and press transitions on controls and the 160ms tab underline are unchanged. Everything is removed under `prefers-reduced-motion`. No scroll reveals, no per-card entrances, no sheet or drawer animation longer than 200ms.

## 9. Accessibility

- Every text token meets 4.5:1 on its surface in both schemes (PerfectBook's audited values); `--seal` and `--ink-4` never carry text under 18px.
- Focus: `2px solid --seal` ring at 2px offset on every interactive element, including chips, stones that open events, stage rows, sheet rows and the docked Send.
- Nothing is colour alone: the unread mark pairs with a name in `--ink` and a count; stones pair with a named meta line; stage badges carry the stage word; toggles carry a label and an `aria-checked` state.
- Hit targets: 38px on desktop, 44px on the phone for Send, tab bar items, sheet rows, stage rows, departure rows.
- The reply box, sheet and docked total respect `env(safe-area-inset-bottom)`.
- Tables scroll inside their card; the board scrolls inside its container on desktop and is a list on the phone. The page never scrolls sideways.
- The timeline is a list (`<ol>`) with each event an item; the stream is `aria-hidden`.
- The AI draft is announced as "AI draft, yours to edit" and is an ordinary editable field; there is no path that sends without a press on Send.

## 10. Sibling rules

**Must stay identical to PerfectBook** (and is synced, not re-authored): scheme tokens and the two schemes; the relief tokens and their limits; fonts and the type scale; the rail; buttons, inputs, segment, tabs, badges, tables, cards, captions, flash, callouts, facts, empty state, stat; the four shared drawings and the sketch line; the three motion moments; the accessibility commitments; sentence case; one primary per view.

**Must differ, so the apps read as siblings:** the mark and the ink tile; Everest in headers; the five CRM drawings; the stream timeline; the unread mark; the bottom tab bar and docked reply box on the phone; stage badges; the lead vocabulary (source, fit, automated).

**Must never happen in the CRM:** bookkeeping screens or money entry (bookings, invoices, payments, expenses are read-only views with deep links into PerfectBook); a second orange; uppercase labels; a cool grey; a drawing behind text; a drop shadow heavier than `--raise`; a card inside a card with relief; auto-sent AI replies; a client turning back into a lead, by hand or by automation.

## 11. Responsive behaviour

| Name | Width | Shell | Key changes |
|------|-------|-------|-------------|
| Phone | up to 749px | top bar plus bottom tab bar | one column; two stat tiles per row; inbox one pane at a time with a docked reply box; pipeline is a stage list; quote builder stacks with a docked total; tabs scroll; tables scroll in their card |
| Tablet | 750 to 989px | drawer | two-column grids; inbox side by side from 900px; board scrolls sideways |
| Desktop | 990px and up | 76px rail | full layout as in section 5 |

## 12. Captain's decisions (round 1, 2026-09-14)

Answered inside the Lavish concept and delivered when the captain ended the session. His words as queued:

1. **The mark and its tile.** "Mark: A, the wheel that speaks · tile: ink tile, ochre mark (recommended)".
2. **The sketch list.** "Sketches: 5 keep, 2 drop": S1 Everest keep, S2 Bridge keep, S3 Pass keep, S4 Mani wall drop, S5 Confluence drop, S6 Cairn keep, S7 Stream keep.
3. **Timeline density.** "Timeline: Airy on desktop and phone (recommended)".
4. **The pipeline on the phone.** "Phone pipeline: Stage list (recommended)".
5. **Round-1 approval.** "Approved with conditions. There should be a leads section and a client section as well. All the leads can be converted to clients, but cannot be reveresed. The idea is that in the future I want to implement google ads/meta ads to PerfectCRM through n8n automation and so that leads come in, it gets sent to panda AI which is another web app that I am designing which qualifies leads, then through n8n back to PerfectCRM for status changes, etc.. you get the idea, it will be an entire ecosystem, so I want you to make sure to prepare for this."

The condition is met by sections 4.11 and 4.12, the pipeline groups in 4.6, the Settings card in 4.9, the vocabulary in 2.2, and the Leads screen and lead page in the concept.

### Round 2 (2026-09-14)

Asked which way to take the unreviewed Leads section, the captain answered "2 and yes to the orbs": a round-2 Lavish look at the Leads section only, and the thinking orbs (4.13) as decided. Round 2 put five things in front of him (the ecosystem diagram, the Leads screen, the lead page, the pipeline group labels, the Settings automations card) with one question: approve the Leads section as designed, approve with changes, or not yet.

Round-2 answer, verbatim, delivered when the captain ended the session: "Alright this all looks good, go ahead with this build". The Leads section, the lead page, the pipeline groups, the Settings automations card, the ecosystem diagram and the thinking orbs are approved as designed. This contract is final for the build.

## Appendix A: sketch symbols (inline SVG)

Copy these into `shared/_sketches.html.erb` next to the shared symbols. Stroke is `currentColor`; the `.sk` class supplies colour and opacity.

```html
<!-- Everest group: Nuptse ridge, the summit with its plume, Lhotse. Every CRM page header. -->
<symbol id="sk-everest" viewBox="0 0 600 150" preserveAspectRatio="xMaxYMax meet">
  <path d="M0 146C60 136 120 128 170 118 220 108 260 120 300 112 340 104 380 84 420 92 470 102 520 126 600 140" fill="none" stroke="currentColor" stroke-width="1" opacity=".55"/>
  <path d="M0 134C40 126 84 110 124 98 160 88 184 92 210 80 240 66 258 52 286 48 306 46 318 54 336 40 354 24 368 12 382 10 394 9 402 24 416 42 428 56 444 62 462 50 476 40 486 38 500 48 520 68 548 100 574 118 588 128 596 134 600 138" fill="none" stroke="currentColor" stroke-width="1.2"/>
  <path d="M384 11c14-3 28-1 44 5M388 7c12-4 26-4 40-1" fill="none" stroke="currentColor" stroke-width="1" opacity=".6" stroke-linecap="round"/>
  <path d="M360 30l6 9M346 40l5 8M300 60l4 8M470 50l5 8M488 44l4 7" fill="none" stroke="currentColor" stroke-width="1" opacity=".7"/>
</symbol>
<!-- Bridge: a suspension bridge with prayer flags across a gorge. -->
<symbol id="sk-bridge" viewBox="0 0 300 150">
  <path d="M0 62c18 2 32 8 42 18 8 8 12 20 14 34M300 58c-18 2-34 8-44 18-8 8-12 20-14 34" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
  <path d="M52 86C110 110 190 110 248 84" fill="none" stroke="currentColor" stroke-width="1.3"/>
  <path d="M52 66C110 92 190 92 248 64M52 74C110 100 190 100 248 72" fill="none" stroke="currentColor" stroke-width="1" opacity=".7"/>
  <path d="M100 98v-14M130 104v-14M150 106v-14M170 105v-14M200 101v-14" fill="none" stroke="currentColor" stroke-width="1" opacity=".55"/>
  <path d="M92 80v7h6v-7M122 87v7h6v-7M152 89v7h6v-7M182 87v7h6v-7M212 81v7h6v-7" fill="none" stroke="currentColor" stroke-width="1" opacity=".8"/>
  <path d="M20 140c30-8 60-6 90-2s70 6 100 0 60-6 84-10" fill="none" stroke="currentColor" stroke-width="1" opacity=".55"/>
  <path d="M200 138a4 4 0 1 1 4 4M110 136a4 4 0 1 0-4-4" fill="none" stroke="currentColor" stroke-width="1" opacity=".6"/>
</symbol>
<!-- Pass: prayer flags between two cairns on a high pass, wind lines. -->
<symbol id="sk-pass" viewBox="0 0 300 150">
  <path d="M0 96C40 78 70 62 100 54s60-4 90 8 60 30 110 26" fill="none" stroke="currentColor" stroke-width="1" opacity=".5"/>
  <path d="M0 132c40-10 90-14 150-14s110 4 150 14" fill="none" stroke="currentColor" stroke-width="1.1"/>
  <path d="M40 120a15 4 0 1 0 30 0a15 4 0 1 0-30 0M43 112a12 4 0 1 0 24 0a12 4 0 1 0-24 0M47 104a9 3.5 0 1 0 18 0a9 3.5 0 1 0-18 0M51 97a6 3 0 1 0 12 0a6 3 0 1 0-12 0" fill="none" stroke="currentColor" stroke-width="1" stroke-linejoin="round"/>
  <path d="M230 120a15 4 0 1 0 30 0a15 4 0 1 0-30 0M233 112a12 4 0 1 0 24 0a12 4 0 1 0-24 0M237 104a9 3.5 0 1 0 18 0a9 3.5 0 1 0-18 0M241 97a6 3 0 1 0 12 0a6 3 0 1 0-12 0" fill="none" stroke="currentColor" stroke-width="1" stroke-linejoin="round"/>
  <path d="M57 94C110 118 180 118 243 92" fill="none" stroke="currentColor" stroke-width="1.1"/>
  <path d="M80 102v10h8v-10M110 109v10h8v-10M140 112v10h8v-10M170 111v10h8v-10M200 106v10h8v-10M226 98v10h8v-10" fill="none" stroke="currentColor" stroke-width="1" opacity=".8"/>
  <path d="M262 60c10-3 20-3 30 0M256 70c12-3 24-3 36 0M266 50c8-2 16-2 24 0" fill="none" stroke="currentColor" stroke-width="1" opacity=".5" stroke-linecap="round"/>
</symbol>
<!-- Cairn: stacked stones with a flag, a peak behind. -->
<symbol id="sk-cairn" viewBox="0 0 300 150">
  <path d="M60 100C100 70 140 40 190 34s70 30 110 50" fill="none" stroke="currentColor" stroke-width="1" opacity=".5"/>
  <path d="M0 142c50-10 100-16 150-14s100 8 150 6" fill="none" stroke="currentColor" stroke-width="1.1"/>
  <path d="M100 128a26 6 0 1 0 52 0a26 6 0 1 0-52 0M105 118a21 5 0 1 0 42 0a21 5 0 1 0-42 0M110 109a16 4.5 0 1 0 32 0a16 4.5 0 1 0-32 0M115 101a11 4 0 1 0 22 0a11 4 0 1 0-22 0M120 94a6 3 0 1 0 12 0a6 3 0 1 0-12 0M123 88a3 2.5 0 1 0 6 0a3 2.5 0 1 0-6 0" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/>
  <path d="M126 88V68M126 70l12 3-12 4" fill="none" stroke="currentColor" stroke-width="1" opacity=".7" stroke-linejoin="round"/>
  <path d="M60 138l3-6 2 6M200 136l3-6 2 6M240 134l3-6 2 6" fill="none" stroke="currentColor" stroke-width="1" opacity=".5"/>
</symbol>
<!-- Stream: the river turned on its side; the spine of every client timeline. -->
<symbol id="sk-stream" viewBox="0 0 40 720" preserveAspectRatio="none">
  <path d="M22 0C10 60 34 100 22 160S8 260 22 320 36 420 22 480 8 580 22 640 30 700 20 720" fill="none" stroke="currentColor" stroke-width="1.2"/>
  <path d="M29 0C17 70 41 110 29 170S15 270 29 330 43 430 29 490 15 590 29 650 37 705 27 720" fill="none" stroke="currentColor" stroke-width="1" opacity=".5"/>
</symbol>
<!-- Mark A: the wheel that speaks. -->
<symbol id="sk-mark-a" viewBox="0 0 24 24">
  <rect x="4" y="7" width="9" height="11" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.7"/>
  <path d="M8.5 2.5V7M8.5 18v3.5M8.5 21.5H6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
  <path d="M6.5 11.5c.8-.5 1.2.5 2 0s1.2-.5 2 0M6.5 14.5c.8-.5 1.2.5 2 0s1.2-.5 2 0" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" opacity=".85"/>
  <path d="M16 10a3.5 3.5 0 0 1 0 5M19 7.6a6.6 6.6 0 0 1 0 9.8" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
</symbol>
<!-- Mark B: two wheels (not chosen; recorded for reference only). -->
<symbol id="sk-mark-b" viewBox="0 0 24 24">
  <rect x="2.5" y="7" width="8" height="10" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.6"/>
  <rect x="13.5" y="7" width="8" height="10" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.6"/>
  <path d="M6.5 3v4M6.5 17v4M6.5 21H4.5M17.5 3v4M17.5 17v4M17.5 21h2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
  <path d="M4.5 11c.7-.5 1 .5 2 0s1-.5 2 0M4.5 13.5c.7-.5 1 .5 2 0s1-.5 2 0M15.5 11c.7-.5 1 .5 2 0s1-.5 2 0M15.5 13.5c.7-.5 1 .5 2 0s1-.5 2 0" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" opacity=".85"/>
</symbol>
```

At 16px the mark drops the mantra lines (the two wavy paths at opacity .85) and keeps the drum, axle, handle and arcs; at 24px and above the full drawing is used. The favicon renders the chosen mark in `#e2963f` on a `#14110e` rounded square (radius 4px at 16px, 6px at 32px, 34px at 180px) with a 1px `rgba(226,150,63,.35)` inner ring.

## Appendix B: thinking orbs port contract

The CRM ships a vanilla port of two of the nine library states. What the port keeps verbatim from thinking-orbs (MIT): `BASE_PROFILES.ribbon` and `.morph`, the `PRESETS` for `ribbon` and `morph` at 64 and 20, `scaleCounts`, `scaleRadii`, `fibDir`, `makeProj`, `radiusScale`, `finalizeFrame`, `frameRibbon`, `frameMorph`, the reduced-motion frame at `t = 0.6`, the offscreen and hidden-tab pause, the DPR cap of 2. What it changes: the painter (one brand colour per scheme, depth as alpha), theme resolution (`[data-scheme]` ancestor, then `prefers-color-scheme`), and the mount API (`data-state`, `data-size`, optional `aria-label`). The concept's `parts/06-orbs.html` is that port and can be lifted into `app/javascript/thinking_orbs.js` as is; keep the MIT notice at the top.

## Appendix C: CRM-only CSS (beyond PerfectBook's application.css)

Class names and values as rendered in the approved concept; the ship task ports them into Tailwind `@layer components` on the shared tokens. PerfectBook's own components are not repeated.

```css
/* Unread mark */
.unread{position:relative;padding-left:34px}
.unread::before{content:"";position:absolute;left:14px;top:20px;width:8px;height:8px;border-radius:2px;background:var(--seal);box-shadow:0 0 0 3px var(--seal-tint)}

/* Timeline */
.timeline{position:relative;padding:8px 24px 16px;display:flex;flex-direction:column;gap:18px}
.timeline .stream{position:absolute;left:44px;top:0;bottom:0;width:26px;height:100%}
.ev{position:relative;display:grid;grid-template-columns:44px minmax(0,1fr);gap:0 14px;align-items:start}
.ev .stone i{position:absolute;left:14px;top:9px;width:11px;height:11px;border-radius:50%;background:var(--paper-2);border:1.5px solid var(--ink-4);box-shadow:var(--raise-sm)}
.ev.in .stone i{background:var(--seal);border-color:transparent;box-shadow:0 0 0 3px var(--seal-tint)}
.ev.out .stone i{background:var(--ink-3);border-color:transparent}
.ev.pb .stone i{background:var(--info-mark);border-color:transparent}
.ev.q .stone i{background:var(--seal);border-color:transparent}
.ev .meta{display:flex;flex-wrap:wrap;gap:6px 10px;align-items:center;font-size:12px;color:var(--ink-3);margin-bottom:6px}
.ev .meta b{color:var(--ink);font-weight:600}
.msg{border-radius:12px;padding:14px 16px;font-size:13.5px;line-height:1.55;color:var(--ink-2);max-width:56ch}
.ev.in .msg{background:var(--paper-2);box-shadow:var(--raise);border:1px solid var(--edge)}
.ev.out .msg{background:var(--paper-3);box-shadow:var(--press)}
.ev.out{margin-left:40px}
.ev.note .msg{background:var(--band);border-left:3px solid var(--ink-4);border-radius:10px}
.ev.q .msg,.ev.pb .msg{background:transparent;border:1px solid var(--rule);display:flex;flex-wrap:wrap;align-items:center;gap:8px 14px;padding:10px 14px}
.ev .msg .more{display:inline-block;margin-top:6px;font-size:12px;color:var(--seal-text);font-weight:500}

/* Reply box, chips, AI draft */
.reply{position:relative;padding:18px 24px 22px;background:var(--sk-line) left top/720px 6px repeat-x}
.reply .box{margin-top:12px;min-height:104px}
.reply .tools{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;margin-top:12px}
.chip{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:6px 12px;font-size:12.5px;font-weight:500;color:var(--ink-2);background:var(--paper-2);box-shadow:var(--raise-sm);border:1px solid var(--edge);white-space:nowrap}
.chip svg{width:13px;height:13px;color:var(--seal)}
.chip-tag{background:var(--band);box-shadow:none;border-color:transparent}
.draft{background:var(--seal-tint);border-radius:10px;padding:12px 14px;font-size:13.5px;line-height:1.55;color:var(--ink);border:1px dashed rgba(201,111,26,.45)}
.draft .tag{display:flex;align-items:center;gap:6px;font-size:11.5px;font-weight:600;color:var(--seal-text);margin-bottom:6px}

/* Leads: source, fit, inline unread mark, automation events, board groups */
.mark-inline{display:inline-block;width:8px;height:8px;border-radius:2px;background:var(--seal);box-shadow:0 0 0 3px var(--seal-tint);margin-right:12px;vertical-align:middle}
.src{display:inline-flex;align-items:center;gap:6px;font-size:12.5px;color:var(--ink-2);white-space:nowrap}
.src svg{width:14px;height:14px;color:var(--ink-4);flex:none}
.fit{display:flex;align-items:center;gap:8px;min-width:120px}
.fit .bar{width:56px;flex:none}
.fit span{font-size:12.5px;white-space:nowrap}
.ev.auto .stone i{background:var(--paper-2);border:2px solid var(--info-mark);box-shadow:none}
.ev.auto .msg{background:transparent;border:1px dashed var(--rule);display:flex;flex-wrap:wrap;align-items:center;gap:8px 14px;padding:10px 14px}
.board-groups{display:grid;grid-template-columns:repeat(7,minmax(128px,1fr));gap:12px;margin-bottom:6px}
.board-groups span{font-size:12px;font-weight:500;color:var(--ink-3);padding:0 4px 6px;background:var(--sk-line) left bottom/720px 6px repeat-x}
.board-groups .g-leads{grid-column:span 4}.board-groups .g-clients{grid-column:span 2}.board-groups .g-lost{grid-column:span 1;color:var(--ink-4)}

/* Thinking orbs: the composing block in the reply box */
.composing{display:flex;align-items:center;gap:14px;border-radius:10px;background:var(--seal-tint);border:1px dashed rgba(201,111,26,.45);padding:12px 14px;min-height:96px}
.composing b{display:block;font-size:13.5px;color:var(--ink);font-weight:600}
.composing span{display:block;font-size:12px;color:var(--ink-3);margin-top:2px}
.badge canvas,.stat-value canvas{display:inline-block;vertical-align:middle}

/* Pipeline board and cards */
.board{display:grid;grid-template-columns:repeat(7,minmax(128px,1fr));gap:12px;overflow-x:auto}
.col-head{display:flex;align-items:baseline;justify-content:space-between;gap:8px;padding:4px 4px 10px;background:var(--sk-line) left bottom/720px 6px repeat-x}
.kcard{position:relative;border-radius:12px;background:var(--paper-2);box-shadow:var(--raise);border:1px solid var(--edge);padding:10px 10px 8px 12px;display:flex;flex-direction:column;gap:4px;cursor:grab}
.kcard.unread-k::after{content:"";position:absolute;left:-1px;top:12px;bottom:12px;width:3px;border-radius:999px;background:var(--seal)}
.kcard.ghost{border:1px dashed var(--ink-4);background:transparent;box-shadow:none;opacity:.7}

/* Phone (max-width 749px): bottom bar, docked reply, sheet, stage list, docked total */
.tabbar{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));position:fixed;left:0;right:0;bottom:0;padding:8px 6px calc(10px + env(safe-area-inset-bottom));background:color-mix(in srgb,var(--paper-2) 94%,transparent);backdrop-filter:blur(10px);border-top:1px solid var(--rule)}
.tabbar a{position:relative;display:flex;flex-direction:column;align-items:center;gap:3px;font-size:10.5px;font-weight:500;color:var(--ink-3)}
.tabbar a.on{color:var(--ink)} .tabbar a.on svg{color:var(--seal)}
.tabbar a.on::before{content:"";position:absolute;top:-9px;width:22px;height:3px;border-radius:999px;background:var(--seal)}
.reply.docked{position:fixed;left:0;right:0;bottom:0;padding:10px 14px calc(14px + env(safe-area-inset-bottom));background:var(--paper);background-image:var(--grain);box-shadow:0 -8px 20px rgba(20,17,14,.08);border-top:1px solid var(--rule)}
.sheet{position:fixed;left:0;right:0;bottom:0;border-radius:18px 18px 0 0;background:var(--paper-2);box-shadow:0 -12px 30px rgba(20,17,14,.18);padding:10px 16px calc(18px + env(safe-area-inset-bottom))}
.sheet li{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:12px 0;border-bottom:1px solid var(--rule-2);min-height:48px}
.stage-row{display:flex;align-items:center;gap:12px;border-radius:12px;background:var(--paper-2);box-shadow:var(--raise);border:1px solid var(--edge);padding:14px 16px;min-height:60px}
.stage-row.open{box-shadow:var(--press);background:var(--paper-3)}
.stage-row .cnt{font-family:var(--font-display);font-size:22px;color:var(--ink);font-variant-numeric:tabular-nums}
.sticky-send{position:fixed;left:0;right:0;bottom:0;display:flex;gap:10px;align-items:center;justify-content:space-between;padding:12px 16px calc(14px + env(safe-area-inset-bottom));background:color-mix(in srgb,var(--paper-2) 94%,transparent);backdrop-filter:blur(10px);border-top:1px solid var(--rule)}
```
