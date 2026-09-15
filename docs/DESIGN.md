# Design System for PerfectCRM

> Category: Travel & Hospitality, internal client-communication app
> Sibling of PerfectBook. Same paper, ink, ochre seal and soft relief; its own mark, mountain, drawings and phone layout.

This file is the brand contract for PerfectCRM, the client relationship and communication hub of Sherpa Holidays, planned at perfectcrm.sherpaholidays.com. It is written in the Open Design format so that an implementation crew can build the app from it without the concept's author.

PerfectCRM is a **sibling of PerfectBook, not a twin**. The parent contract is PerfectBook's `docs/DESIGN.md` (sections 1 to 8 measure the public website, section 9 is the Washi token set). This file does not restate the website measurements. It restates the tokens the CRM commits to (so the file stands alone), then records what the CRM shares verbatim with PerfectBook, what it adds, and what it must never do. [DESIGN-SYNC.md](DESIGN-SYNC.md) describes the current source locations and the proposed shared-package workflow.

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

The CRM uses PerfectBook's token names and values without change. They are listed here so this file stands alone; the runtime source of truth is the `--pb-*` base tokens in [application.css](../app/assets/tailwind/application.css). The shared package is proposed (see [DESIGN-SYNC.md](DESIGN-SYNC.md)).

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
| Fit | `.fit`: a 56px `.bar` (band semantics are owned by [README Leads](../README.md#leads)) plus the word and the number ("Strong · 82", "Possible · 61", "Weak · 34"); "Scoring" as an info badge with the robot icon while Panda AI has not answered | Colour, word and number together; never the bar alone. |
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
- **Bottom tab bar (phone only, under 750px).** Five items: Today, Inbox (with count), Leads, Clients, More (Pipeline, Quotes, Templates, Settings; More is lit when any of those is open). 20px icons, 10.5px labels, a 3px seal bar above the active item, `--paper-2` at 94 percent with backdrop blur, safe-area inset padding. More opens the navigation drawer; the top bar also retains Open menu beside the mark and wordmark. The inbound thread retains the shared tab bar, with Jump to newest above it. The quote builder retains the tab bar with its sticky total and send controls above it; current outbound composer usage is documented in [README, Replying](../README.md#replying).
- **Browser tab.** Favicon is the CRM mark on the ink tile at 16, 32, 180 and 512px; `theme-color` `#fcfaee` for Paper and `#14110e` for Night.

### 4.2 Page header

`shared/_page_header` unchanged in shape (eyebrow, Gelasio title, subtitle, actions bottom-right, at least 160px tall on desktop), with `sketch :everest` in place of `:ridge`. The drawing stays top-right, draws itself on load, and shrinks to 200px wide on the phone without covering text. One `.btn-primary` per header; secondary actions are raised paper and hide on the phone when the primary covers the same job.

### 4.3 Lists and rows

- `.rowlist` is the CRM's list-in-a-card: 12px 24px rows separated by `--rule-2`, a name in `--ink` 500, a one-line secondary in `--ink-3` that truncates with an ellipsis, and a right-aligned meta column (time, badge, small button). Rows wrap on narrow widths so a button never crushes the name.
- `.unread` adds the unread mark at left (34px indent).
- Check rows (follow-ups) use a 18px pressed square (`.check`), `--good-mark` when done; done rows stay for the day with the name struck through in `--ink-3`.

### 4.4 Inbox and the timeline

- **Two panes on desktop:** a 300px client list card (search well on top, rows with name, time, last line, stage badge and trip) and the thread card. On the phone one pane shows at a time; the thread has a back link to the list.
- **Filter tabs:** Icons and counts on each tab; [Mail in the README](../README.md#mail) owns the available filters and unread behavior.
- **The stream.** `sketch :stream` (the river drawn vertically, two strokes) runs the full height of the timeline, 26px wide, 44px from the left edge of the card (12px on the phone). Each event is a `.ev` row: a stone (11px circle on the stream), a meta line (icon, name in `--ink` 600, time in `--ink-3`, optional badge), and a body.
- **Event bodies.** Inbound email: raised `--paper-2` card, radius 12px, 14px 16px padding, 13.5px text, first four lines then "Read the full email" in `--seal-text`. Outbound: pressed `--paper-3` card, indented 40px (20px phone). Note: `--band` with a 3px `--ink-4` left rule, radius 10px. Quote sent and PerfectBook events: transparent, `1px solid --rule`, contents in one row (badge, description, small link "Open in PerfectBook" with the external icon in `--seal`). For email ordering and history navigation, see [Mail in the README](../README.md#mail).
- **Reply box.** Sits at the bottom of the thread card under a drawn rule (`--sk-line`). "Reply to Amara Okafor · Re: subject" line (hidden on the phone), a pressed `.textarea` (104px tall, 72px on the phone), then a tools row: template chips on the left (the three most-used templates plus "Draft a reply" with the sparkle icon), the `.btn-primary` Send on the right. On the phone the reply box is docked (`position: absolute; bottom: 0` inside the app shell) over the home indicator, on `--paper` with grain, a top hairline and a soft upward shadow; the chips scroll in one row without a visible scrollbar; Send is at least 44px tall and 92px wide.
- **Templates sheet (phone).** Tapping the sparkle chip opens a bottom sheet (`--paper-2`, radius 18px top, a 36px grab bar, backdrop `rgba(20,17,14,.28)`): a "Draft a reply" row on `--seal-tint`, the three most-used templates as 48px rows with name and first line, then "All templates". One tap fills the reply box and closes the sheet.
- **AI draft.** Appears inside the reply box area as the `.draft` block described in 2.2, with the tag "AI draft, yours to edit". Tools become Edit and Try again; Send is unchanged. Nothing sends until Send is pressed; there is no auto-send setting.
- **Template chips.** `.chip`: pill, `--paper-2`, `--raise-sm`, 12.5px 500 text, a 13px `--seal` icon, 32px tall, 8px gaps. Tag chips (`.chip-tag`) are flat on `--band`.

### 4.5 Client page

Header with back link, eyebrow "Client · {stage}", the client's name as title, a one-sentence subtitle (where they are, what trip, who referred them). Tabs: Overview, Timeline, People, Quotes, Bookings, Notes, each with a count. Cards: Facts (`.facts` grid plus tag chips), Latest (last message with a Reply button and the next promise), People (table with passport status badges), Quotes (table with status badges and money right-aligned), Bookings in PerfectBook (table labelled "Read only", the booking reference is the deep link, empty state with enso and the cairn), Notes (rowlist). Foot: the scene specified in section 4.10 with a one-line caption.

### 4.6 Pipeline

- **The trail.** Above the board, `bookings/_status_stepper`'s pattern: one drawn rule with seven dots, New, Chatting, Quoted, Nudged, Won, Post-trip, Lost; done stages in `--good-mark`, the selected stage as a 16px `--seal` dot with a tint halo. One caption line explains the reading order.
- **Groups over the board.** A label row on the same seven-column grid names the halves: "Leads" over New to Nudged, "Clients" over Won and Post-trip, "Off the path" over Lost, each on a drawn rule. Dropping a card on Won asks "Convert to client?"; once confirmed the card cannot be dragged back to a lead column.
- **Board (desktop).** Seven columns, `repeat(7, minmax(128px, 1fr))`, 12px gaps, inside a container that scrolls sideways only if narrower than 968px. Column head: icon in `--seal`, name 13.5px 600, count 12px `--ink-3`, a drawn rule below; a `col-sum` line ("$42,230 out") where money applies. Cards (`.kcard`): raised, radius 12px, 10px padding, name 13px 500, trip 12px `--ink-3` truncated, a bottom row with age of last message and money or guests; a 12px grip icon top-right; a 3px `--seal` left edge when the client is waiting on a reply (`.kcard.unread-k`). A dragged card leaves a dashed `--ink-4` ghost at its target. Counts and totals update on drop; nothing else animates.
- **Stage list (phone).** Seven `.stage-row`s: a 34px `--band` icon tile, name 14.5px 500, a one-line hint or the money out, the count in Gelasio 22px, a chevron. Tapping opens the stage's cards beneath it (the row goes pressed); moving a record uses a menu on the card. [Pipeline in the README](../README.md#pipeline) owns the allowed moves. The captain approved the stage list; see section 12.

### 4.7 Quote builder

On a new quote, "Trip and departure" spans the page above the builder: a `.select` fed by PerfectBook's catalog, then raised radio rows with dates and seats left; the chosen row goes pressed with a seal-tinted background. Pricing follows [README, Quotes](../README.md#quotes). The form has two columns on desktop (`3fr 2fr`): left, "Lines" (quantity, each and total right-aligned, an Add line button in the header) and "Note to the client" (note and inclusions textareas); right, "Summary" (guests, deposit, balance due date, valid until, then the total in Gelasio 30px, Send quote and Save draft) and "When they accept" (three checked lines). Editing a draft puts trip and departure selects in the left column. Below 640px, each line stacks its full-width description above one row containing price, quantity, total, and Remove. Below the desktop layout, the columns stack and a sticky bar adds the total (Gelasio 22px, guests beneath) and a 44px Send quote; the summary buttons remain available. Phone navigation placement follows section 4.1.

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
- **The inbound API is visible.** Settings shows the public site key, masked relay secret, last use, and separate rotation controls. Credential behavior is defined in the [website intake contract](leads-intake.md). The Leads page's Automations card lists each automation with its last run and an Automated or Manual badge.
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
- **Implementation.** A vanilla port (`app/javascript/thinking_orbs.js`, MIT notice kept) with a Stimulus controller `orb` that takes `state` and `size` values and mounts on a `<canvas data-controller="orb">`. The React component is not used. See Appendix B for the port's contract.

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

Budget per surface: the Everest ridge in the header and one river or scene lower down. The stream is structural, not decorative, and does not count against the budget. Required ensos are outside the budget. Appendix A points to the authoritative SVG symbols.

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

**Must stay identical to PerfectBook** (shared-package sync is proposed in DESIGN-SYNC.md): scheme tokens and the two schemes; the relief tokens and their limits; fonts and the type scale; the rail; buttons, inputs, segment, tabs, badges, tables, cards, captions, flash, callouts, facts, empty state, stat; the four shared drawings and the sketch line; the three motion moments; the accessibility commitments; sentence case; one primary per view.

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

The shipped symbols live in [shared/_sketches.html.erb](../app/views/shared/_sketches.html.erb); viewboxes and aspect-ratio handling live in [ApplicationHelper](../app/helpers/application_helper.rb). Edit those sources instead of maintaining a second SVG copy here.

At 16px the mark drops the mantra lines (the two wavy paths at opacity .85) and keeps the drum, axle, handle and arcs; at 24px and above the full drawing is used. The favicon renders the chosen mark in `#e2963f` on a `#14110e` rounded square (radius 4px at 16px, 6px at 32px, 34px at 180px) with a 1px `rgba(226,150,63,.35)` inner ring.

## Appendix B: thinking orbs port contract

The port lives in [thinking_orbs.js](../app/javascript/thinking_orbs.js), with its MIT notice and upstream attribution. It owns the geometry, presets, painter, shared clock, scheme resolution and visibility tracking described in section 4.13.

Mount through the `orb` helper in [ApplicationHelper](../app/helpers/application_helper.rb), or a canvas with `data-controller="orb"`, `data-orb-state-value="composing"` or `"shaping"`, and `data-orb-size-value="20"` or `"64"`. The [orb controller](../app/javascript/controllers/orb_controller.js) disposes the previous mount before replacing it and releases its resources on disconnect.

Supply a specific accessible name with `orb(:shaping, label: "Panda AI is scoring this lead")`, or `data-orb-label-value` on a manually mounted canvas. This label persists across state changes; without it, the controller updates the default accessible name to match the state.

## Appendix C: CRM-only CSS (beyond PerfectBook's application.css)

The CRM layer in [application.css](../app/assets/tailwind/application.css) owns the shipped component rules and responsive overrides. It uses the shared `--pb-*` tokens in the same file. [The design preview](../app/views/design/show.html.erb) demonstrates the kit; see [README navigation](../README.md#navigation) for access.
