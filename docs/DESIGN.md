> **PerfectCRM inherits this contract.** Adapted from PerfectBook's `docs/DESIGN.md`, this is PerfectCRM's visual contract for Washi tokens, Paper/Night schemes, and sketches. References below to PerfectBook screens and its 2026-09-13 review describe the source design, not shipped CRM features. Do not invent a separate CRM visual identity.

---

# Design System Inspired by Sherpa Holidays

> Category: Travel & Hospitality
> Family-run Himalayan adventure travel. Cream paper, ink, one ochre accent, mountain photography, Georgia headlines.

This file is the brand contract for PerfectBook, the internal bookkeeping and compliance app of Sherpa Holidays. Sections 1 to 8 record what the public website does, measured from computed styles in Chromium on 2026-09-13 (viewport 1440 x 900) with `chrome-devtools-axi`. Section 9 turns those measurements into the token set PerfectBook commits to, including the light and dark schemes, the soft-relief (neumorphic) depth model, and the sketch accents chosen for the redesign. Values in section 9 that are derived rather than measured are marked as such.

## 1. Visual Theme & Atmosphere

Sherpa Holidays reads as a premium family outfitter rather than a booking engine. The page is warm cream paper, the headlines are a large, quiet Georgia serif set almost black, and almost all of the colour on the page comes from photography: Everest and Ama Dablam under blue sky, prayer flags, the Boudhanath stupa, trekkers on a trail. The chrome around the photographs is deliberately thin: a transparent header over the hero image, uppercase Montserrat navigation at 12px, and one ochre-orange used for the primary call to action, the active navigation item, eyebrow labels, and tab highlights.

The rhythm is editorial. Every page opens with a full-bleed photograph behind white serif type, then settles into cream bands separated by 100px of vertical air, with white cards in three-up grids. Corners are consistently 12px on cards, media, and the newer call-to-action buttons; the base theme still declares 0px buttons and inputs, so the site carries two generations of geometry (square theme controls, rounded custom blocks). Depth is almost absent: cards have no shadow, borders are hairlines at 8 to 14 percent black, and the only shadow on the homepage is a soft `0 4px 14px rgba(0,0,0,0.2)` under the hero button.

Text colour steps down through warm greys rather than pure grey, and the footer flips to white text on a dark photograph. The overall atmosphere is paper, ink, and mountain light: restrained, warm, and confident enough to let one orange do all the pointing.

**Key Characteristics:**
- Cream paper canvas (`#fcfaee`) with white cards (`#ffffff`) and a sand band (`#f1e3d5`) for warmth; no cool greys anywhere
- One accent, ochre orange (`#c96f1a`), for actions, active navigation, eyebrows, and tab states; its hover is `#a85a12`
- Georgia serif for every headline at weight 400 with tight tracking (`-0.9px` at 60px, `-1.08px` at 72px), Montserrat for everything else
- Uppercase, tracked Montserrat for navigation, kickers, and buttons (12 to 16px, letter-spacing 1 to 3px)
- Photography carries the drama: full-bleed Himalayan images behind white serif headlines with a `rgba(0,0,0,0.32)` wash
- 12px radius on cards, photos, popups, and custom buttons; pill (`4rem`) badges; hairline borders at 8 to 14 percent
- Depth is tonal, not shadowed: white on cream, cream on sand, black photo bands, one soft shadow under the hero button
- Generous vertical rhythm: 100px between desktop sections, 40px grid gutters, 96px header offset

## 2. Color Palette & Roles

> **Source Pages:** `https://www.sherpaholidays.com/`, `https://www.sherpaholidays.com/pages/about-us`, `https://www.sherpaholidays.com/collections/province`, `https://www.sherpaholidays.com/products/everest-base-camp-premium-trek`, `https://www.sherpaholidays.com/blogs/nepal-travel-guide`

The theme exposes its palette as CSS custom properties on `:root` (`--sherpa-*` and the Shopify `--color-base-*` / `--gradient-base-*` families). Values below were read from those variables and confirmed against computed backgrounds of blocks taller than 120px.

### Primary
- **Sherpa Cream** (`#fcfaee`, `--sherpa-cream`, `--gradient-base-background-4`): Page canvas on every page; the review band; the newsletter input fill. The most frequent large background (5 blocks on the homepage).
- **Sherpa Ink** (`#14110e`, `--sherpa-ink`): The brand's near-black, warmed toward brown. Declared for dark bands and used for the rule colour; headline text itself is computed as pure black.
- **Ochre Orange** (`#c96f1a`, `--sherpa-orange`, `--color-base-accent-2`): The only accent. Solid CTA fill, active nav link, eyebrow labels ("OUR STORY", "SHERPA FAMILY OWNED"), active product tab, search button.

### Secondary & Accent
- **Ochre Hover** (`#a85a12`, `--sherpa-orange-hover`): Button hover state.
- **Ochre Tint** (`rgba(201,111,26,0.10)`, `--sherpa-orange-tint`): Selected and highlighted backgrounds.
- **Sand** (`#f1e3d5`, `--color-base-background-3`): Warm band behind "Raised by the Himalayas" and blog sections; outline-button label colour in the theme.
- **Old Paper** (`#f0ecdc`, `--gradient-base-accent-8`): The vintage band on the About page ("Where It All Began"), paired with a brown heading.

### Surface & Background
- **Card White** (`#ffffff`, `--color-base-background-1`): Trip cards, review cards, product hero panel.
- **Warm White** (`#fffdf6`, `--gradient-base-accent-6` is `#fdfcf4` and the computed page shell is `#fffdf6`): Second-most common large background; the page shell behind sections.
- **Product Shell** (`#fafaf8`): Background behind the product tabs on the trip page.
- **Neutral Shell** (`#f5f5f5`, `#f8f8f8` as `--color-overlay`): Quiet neutral fields on the product page and overlay base.
- **Photo Black** (`#000000`): Hero and video bands behind photography; the header top bar computes as transparent over it.
- **Photo Wash** (`rgba(0,0,0,0.32)`): Overlay between photograph and white type; the product lightbox uses `rgba(0,0,0,0.92)`.
- **Menu Tile Ink** (`#10151b`): The mega-menu destination tiles.

### Neutrals & Text
- **Headline Black** (`#000000`): h1 to h3 on cream and white.
- **Vintage Brown** (`#3d3226`): Heading colour on the Old Paper band.
- **Body Charcoal** (`#333333`): About-page paragraphs at 16px.
- **Body Grey** (`#444444`, `--color-base-accent-3`): Blog body and newsletter copy at 15.5px.
- **Warm Grey** (`#5a5550`): Product description body at 15px weight 300.
- **Muted Grey** (`#666666`): Sub-headings such as "Click on any province" at 24px.
- **Inactive Tab** (`#8b8680`): Non-selected product tabs; below 4.5:1 on cream, used only at 13px uppercase medium.
- **Rule** (`rgba(20,17,14,0.10)`, `--sherpa-rule`): Dividers. Card borders use `rgba(0,0,0,0.08)`; input borders `rgba(0,0,0,0.14)`.
- **On Dark**: white at 100 percent for headlines and navigation, `rgba(255,255,255,0.92)` kicker, `0.82` footer links, `0.75` outline-button border, `0.60` copyright line, `0.55` footer headings.

### Semantic & Accent
- The website has no status palette: no success, warning, or danger colours were observed on any measured page. PerfectBook supplies its own (section 9).
- **Prayer-flag colours** (blue, white, red, green, yellow) appear only in photography and are not used as UI colour.

### Gradient System
- None in use. The theme declares gradient slots (`--gradient-base-background-6` teal `#007c8a`, `--gradient-base-accent-5` dusty rose `#d4baba`, `--gradient-base-accent-9` `#dccfcf`) that no measured page renders; treat them as theme residue, not brand.

## 3. Typography Rules

### Font Family
- **Display Family:** `Georgia, "Times New Roman", serif` (computed on every h1, h2, and card h3). Georgia is a proprietary Microsoft face; PerfectBook ships **Gelasio** (SIL OFL, metric-compatible with Georgia) with Georgia as fallback.
- **Text Family:** `Montserrat, sans-serif` (theme variables `--font-heading-family` and `--font-body-family` both resolve to Montserrat at weight 400; bold is 700). PerfectBook self-hosts the variable Montserrat woff2 in `app/assets/fonts/`.
- **Stray families:** Arial appears in a newsletter block and the lightbox close button; treat as an authoring accident, not brand.

### Hierarchy (measured)
| Role | Size | Weight | Line Height | Letter Spacing | Case | Source |
|------|------|--------|-------------|----------------|------|--------|
| Hero headline | 72px | 400 | 82.8px (1.15) | -1.08px | Sentence | Homepage h1, white on photo |
| Page h1 | 60px | 400 | 80.4px (1.34) | -0.9px | Sentence | About, collections (visually hidden h1) |
| Blog hero | 60px | 900 | 66px (1.10) | -2px | Uppercase | "SHERPA STORIES" |
| Section h2 | 48 to 58px | 400 | 1.15 to 1.34 | -0.5 to -0.96px | Sentence | "Where Will You Go?", "Explore Nepal by Province" |
| Product h1 | 48px | 400 | 57.6px (1.20) | -0.72px | Sentence | Trip page title |
| Mid h2 | 36 to 44px | 400 | 1.12 to 1.34 | -0.53 to +0.5px | Sentence | Blog featured, FAQ title |
| Small h2 | 24 to 32px | 400 | 1.17 to 1.34 | 0 to 0.5px | Sentence | "Travel Dates", "Flexible Bookings", vintage band |
| Card title | 18 to 20px | 600 (700 on blog) | 1.30 | -0.3px / +0.3px | Sentence | Trip cards, province cards |
| FAQ question | 18px | 500 | 24px (1.34) | 0.3px | Sentence | Product FAQ |
| Sub-headline | 20 to 24px | 400 to 700 | 1.6 to 1.9 | normal | Sentence | Hero sub, map subtitle |
| Body | 15 to 16px | 400 (300 on product) | 25.6 to 28.8px (1.6 to 1.8) | normal | Sentence | Paragraphs |
| Body small | 13 to 14px | 400 to 500 | 22 to 26px | 0 to 0.28px | Sentence | Links, copyright |
| Nav link | 12px | 700 | normal | 1.68px | Uppercase | Header navigation |
| Kicker pill | 13px | 600 | 24px | 3px | Uppercase | Hero "A THREE-GENERATION SHERPA FAMILY COMPANY" |
| Eyebrow | 12 to 13px | 400 to 600 | normal | 1 to 2px | Uppercase | "STARTING FROM", "OUR STORY" (orange) |
| Footer heading | 12px | 600 | 18px | 2.16px | Uppercase | Footer column titles at 55 percent white |
| Button | 14 to 16px | 500 to 600 | normal | 0 to 1px | Uppercase (hero) or sentence (cards) | CTAs |
| Tab | 13px | 400 / 500 active | normal | 1px | Uppercase | Product tabs |
| Price | 36px approx | 400 | normal | normal | numerals | "$3,975.00" |

### Principles
- **Serif carries identity, sans carries work.** Every headline is Georgia at weight 400; weight, not size, is what keeps the serif calm. Montserrat does labels, body, and controls.
- **Tight tracking scales with size.** Roughly -0.015em on display sizes, easing to neutral or slightly positive below 24px.
- **Uppercase is a marketing register.** Navigation, kickers, and hero buttons are tracked uppercase on the website. PerfectBook keeps sentence case (a standing captain instruction) and borrows only the tracking discipline for tiny labels.
- **Line height opens up in body copy.** 1.6 to 1.8 on paragraphs, 1.1 to 1.2 on display lines.

### Note on Font Substitutes
- Gelasio for Georgia (metric-compatible, so line breaks match). Montserrat is a Google Font and ships as-is.
- When Gelasio renders slightly lighter than Georgia, keep weight 400; do not compensate with 500.

## 4. Component Stylings

### Buttons
- **Primary (custom blocks):** `#c96f1a` fill, white text, 12px radius, 14 to 16px Montserrat 500 to 600, padding 14 to 20px vertical by 32 to 50px horizontal, `0.3s` transition; the hero version adds `0 4px 14px rgba(0,0,0,0.2)`.
- **Primary (theme base):** `#c96f1a` fill with 0px radius (search button, base `--buttons-radius: 0px`). PerfectBook follows the 12px family, not the square theme default.
- **Secondary (outline on photo):** transparent fill, `1px solid rgba(255,255,255,0.75)`, white text, 12px radius, same padding as primary.
- **Dark utility:** `#000000` fill, white 11.5px 700 uppercase text, 12px radius (blog newsletter).
- **Hover:** fill moves to `#a85a12`; product buttons carry a `1px solid #c96f1a` border that persists.

### Cards & Containers
- **Trip and story cards:** `#ffffff` on cream, 12px radius (`--card-corner-radius: 1.2rem`), no border, no shadow (`--card-shadow-opacity: 0`), image on top with 12px media radius, 20px Georgia 600 title, 14px Montserrat 500 link.
- **Review cards:** `#ffffff`, 12px radius, `1px solid rgba(0,0,0,0.08)`, padding `26px 26px 22px`.
- **Text boxes and popups:** 12px radius, 0px border, shadow opacity 0 (text boxes) or 0.2 at `6px 6px 10px` (popups).
- **Menu tiles:** photo tiles at `#10151b` with 10px radius and 11.5px captions at 82 percent white.
- **Bands:** cream, sand, or old paper full-width sections; black photo bands with a 0.32 wash.

### Inputs & Forms
- **Theme inputs:** 0px radius, 1px border, no shadow (`--inputs-radius: 0px`, `--inputs-border-width: 1px`).
- **Custom newsletter input:** `#fcfaee` fill, `1px solid rgba(0,0,0,0.14)`, 12px radius, 50px tall, 18px horizontal padding, 14.5px text.
- **Search:** transparent 45px field, 18px Montserrat 600 with 0.8px tracking, orange 35px square submit.

### Navigation
- **Header:** transparent over the hero photograph, 68px tall plus a 58px contact top bar; logo 147 x 58 (white wordmark with an orange prayer-wheel mark); links 12px Montserrat 700 uppercase 1.68px tracking, white, active link `#c96f1a`.
- **Product tabs:** 13px uppercase 1px tracking, active `#c96f1a` weight 500, inactive `#8b8680` weight 400, on `#fafaf8`.
- **Footer:** dark photograph with 12px 600 uppercase headings at 55 percent white, 15px links at 82 percent white, copyright 13px 500 at 60 percent.

### Image Treatment
- Full-bleed landscape photography behind hero type, darkened with `rgba(0,0,0,0.32)`; the header floats over it.
- Content photographs are 12px-rounded blocks, either full column width or in three-up grids with 40px gutters; hover scales images over `0.55s`.
- Subject matter: peaks, prayer flags, stupas, teahouse villages, guides and guests on trail. Warm, high-key daylight.

### Other Distinctive Components
- **Kicker pill:** 13px 600 uppercase 3px tracking, `rgba(0,0,0,0.18)` fill, `1px solid rgba(255,255,255,0.35)`, 100px radius, on the hero.
- **Price block:** 12px uppercase 1px-tracked label above a 36px numeral, separated from the details grid by a `rgba(20,17,14,0.10)` rule.
- **Badges:** pill (`--badge-corner-radius: 4rem`).

## 5. Layout Principles

### Spacing System
- Section rhythm `100px` desktop, `70px` mobile (`--spacing-sections-*`).
- Grid gutters `40px` desktop, about `31px` mobile (`--grid-desktop-*-spacing`).
- Component padding clusters at 14, 16, 18, 20, 26, and 32 to 50px; base unit is effectively 4px with 8px steps.
- Header offset `96px` (`--sherpa-header-offset`).

### Grid & Container
- Page width `156rem` (1560px) with 3 percent full-width spacing; hero copy caps at 940px, body columns at 553 to 660px (about 65 to 75 characters).
- Three-up card grids on the homepage and collection pages; two-column image-and-text bands on About and Destinations.

### Whitespace Philosophy
- Air above and below every band; headlines get room to sit alone.
- Copy columns stay narrow beside wide photographs, an asymmetric balance the redesign leans into.

### Border Radius Scale
- **0px:** theme-default buttons, inputs, variant pills (legacy geometry).
- **10px:** mega-menu tiles.
- **12px:** cards, media, popups, custom buttons, custom inputs.
- **100px / 4rem / 999px:** kicker pill, badges, circular close buttons.

## 6. Depth & Elevation

| Level | Treatment | Use |
|------|-----------|-----|
| Level 0 | Flat cream, warm white, sand, old paper | Page and section bands |
| Level 1 | White card on cream, no shadow | Trip, story, province cards |
| Level 2 | Hairline border `rgba(0,0,0,0.08)` to `0.14` | Review cards, inputs |
| Level 3 | `0 4px 14px rgba(0,0,0,0.20)` | Hero primary button only |
| Level 4 | `6px 6px 10px` at 0.2 | Popups and modals |
| Photo bands | `#000` plus `rgba(0,0,0,0.32)` wash | Heroes, video, footer |

Depth on the website is tonal. The redesign adds a soft-relief model (section 9) that stays within this restraint: low-opacity dual shadows, never the heavy grey drop shadow.

## 7. Do's and Don'ts

### Do
- Use cream `#fcfaee` as the canvas and white or warm white for raised content; keep every neutral warm.
- Reserve ochre `#c96f1a` for actions, the active navigation item, and small emphasis; let one accent do all the pointing.
- Set headlines in Georgia (Gelasio) weight 400 with tight tracking; keep Montserrat for labels, body, numbers, and controls.
- Keep 12px as the working radius for cards, controls, and media; pills for badges.
- Separate content with tone and air first, hairlines second, shadows last.
- Use photography or ink line drawings of the Himalaya as the only decoration.

### Don't
- Don't introduce cool greys, teal, or the theme's unused gradient slots.
- Don't set ochre text at 13px on cream (`#c96f1a` on `#fcfaee` is 3.5:1); step to `#a85a12` for small text.
- Don't mix square theme controls with rounded custom ones; the app standardises on 12px.
- Don't bold the serif; card titles at 600 are the ceiling, and headlines stay at 400.
- Don't add gradient washes, glows, or heavy drop shadows to chrome.
- Don't shout: uppercase tracking is a website register; the app stays sentence case.

## 8. Responsive Behavior

### Breakpoints
| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | up to 749px | Section spacing 70px, grid gutters about 31px, hidden top contact bar (`hide-mobile`), stacked cards |
| Tablet | 750px to 989px | Two-column grids, header collapses to drawer |
| Desktop | 990px and up | Full navigation, three-up grids, 100px section rhythm |
| Wide | 1560px and up | Container caps at `156rem` |

### Touch Targets
- Buttons are 44 to 72px tall; nav links are small (14px line boxes) and rely on the header's padding.

### Collapsing Strategy
- Hero type scales down in discrete tiers; images stay dominant.
- Card grids stack to one column; the header becomes a drawer.

## 9. PerfectBook Application (the contract)

This is the part the implementation commits to. Layout and information architecture of the app do not change; the material does. Tokens below are the redesign's blend of the website palette, soft relief (neumorphism done quietly), and a Japanese sketch sensibility: ma (negative space), asymmetric balance, thin ink lines, paper grain, one seal-red-orange accent. Measured values are cited; derived values are marked "derived".

### 9.1 Schemes

PerfectBook ships two schemes on the same tokens. **Paper** (light) is the default; **Night** is the ink (dark) scheme. Decided by the captain in the Lavish review on 2026-09-13: direction **Washi**, default scheme "Paper by default, with a night toggle in Settings", sketch intensity "Bold: ridge in every header at full strength, visible grain, enso on every empty state", approved for implementation with the conditions in section 9.8. In round 2 (same day) the captain kept all six drawings of 9.3, kept the three motion moments and the tabs and captions of 9.8, asked for the prayer wheel drawing as the app logo and favicon (9.9), and answered "Round 2 approval: Approved, implement this." The Sumi and Kakejiku values in the concept remain available as token alternatives but are not part of this contract.

| Token | Paper (light) | Ink (dark) | Notes |
|------|---------------|------------|-------|
| `--paper` page | `#fcfaee` (measured) | `#14110e` (measured `--sherpa-ink`) | Body background |
| `--paper-2` raised surface | `#fffdf6` (measured shell) | `#1a1613` (existing app `ink-850`) | Cards, tiles, rail-expanded panel |
| `--paper-3` pressed well | `#f1e3d5` at 45 percent over paper, derived `#f7f0e3` | `#100e0c` (derived) | Inset inputs, bar grooves |
| `--band` | `#f0ecdc` (measured old paper) | `#211c18` (existing `ink-800`) | Quiet section bands, table header row |
| `--ink` text | `#14110e` | `#fcfaee` | Headlines, primary text |
| `--ink-2` | `#3d3226` (measured vintage brown) | `rgba(252,250,238,0.85)` | Secondary headings, table body |
| `--ink-3` muted | `#5a5550` (measured warm grey) | `rgba(252,250,238,0.60)` | Labels, hints, meta |
| `--ink-4` faint | `#8b8680` (measured inactive tab) | `rgba(252,250,238,0.38)` | Disabled, placeholder, decorative lines only |
| `--rule` | `rgba(20,17,14,0.10)` (measured `--sherpa-rule`) | `rgba(252,250,238,0.08)` | Hairlines, sketch strokes at 1px |
| `--seal` accent | `#c96f1a` (measured) | `#e2963f` (existing `brand-soft`) | Stripes, active icon, bar fills, large numbers |
| `--seal-text` | `#9a520f` (derived: the site's hover `#a85a12` is 4.85:1 on paper but drops to 4.3:1 on the ochre tint and the band, so it steps one shade deeper) | `#e2963f` | Orange text at small sizes: eyebrows, tab counts, brand badges |
| `--btn-primary` | `#a85a12` fill, `#fcfaee` text (4.85:1) | `#c96f1a` fill, `#14110e` text (5.17:1) | Hover `#8f4c0e` (derived) light, `#e2963f` dark |
| `--good` | `#3f6a2a` text (derived: `#4f7a36` is 4.25:1 on the good tint), `#8fbf6a` marks | `#8fbf6a` | Existing moss marks |
| `--warn` | `#8a6412` text, `#e0b04a` marks | `#e0b04a` | Existing amber tokens |
| `--bad` | `#93362b` text, `#e07160` marks | `#eb8a7f` text, `#e07160` marks (derived: ember on a danger-tinted row is 3.9:1) | Existing ember marks |
| `--info` | `#2f5f82` text, `#7fb2d9` marks | `#7fb2d9` | Existing sky tokens |
| `--rail` | `#14110e` (ink rail on paper) | `#0f0d0b` (existing `ink-950`) | The 76px rail stays ink in both schemes |

Contrast, computed with the WCAG 2 formula:

| Pair | Ratio | Result |
|------|-------|--------|
| ink `#14110e` on paper `#fcfaee` | 17.96 | AAA |
| ink-2 `#3d3226` on paper | 11.91 | AAA |
| ink-3 `#5a5550` on paper | 7.03 | AAA |
| ink-4 `#8b8680` on paper | 3.44 | UI and large text only |
| seal `#c96f1a` on paper as text | 3.47 | large text only; use the `seal-text` token for small text |
| cream on `#a85a12` primary button | 4.85 | AA |
| ink on `#c96f1a` dark-scheme button | 5.17 | AA |
| good `#3f6a2a`, warn `#8a6412`, bad `#93362b`, info `#2f5f82` on paper | 6.06, 5.12, 7.15, 6.51 | AA or better |
| cream 60 percent on ink `#1a1613` | 6.37 | AA |
| brand-soft `#e2963f` on ink `#1a1613` | 7.42 | AAA |
| moss, amber, ember, sky on ink `#1a1613` | 8.41, 8.97, 5.74, 7.94 | AA or better |

### 9.2 Soft relief (the neumorphic part, kept quiet)

Relief describes only three things: a surface you can act on (raised), a surface that holds a value (pressed), and the page itself (flat). Text never sits on a shadow edge, and no state is conveyed by relief alone.

| Token | Paper | Ink |
|------|-------|-----|
| `--raise` (cards, tiles, buttons at rest) | `-5px -5px 12px rgba(255,255,255,0.9), 6px 6px 14px rgba(20,17,14,0.11)` | `-4px -4px 10px rgba(255,255,255,0.035), 6px 6px 16px rgba(0,0,0,0.55)` |
| `--raise-sm` (badges, small controls) | `-2px -2px 5px rgba(255,255,255,0.9), 3px 3px 7px rgba(20,17,14,0.10)` | `-2px -2px 5px rgba(255,255,255,0.03), 3px 3px 8px rgba(0,0,0,0.5)` |
| `--press` (inputs, bar grooves, active rail item) | `inset 3px 3px 8px rgba(20,17,14,0.11), inset -3px -3px 8px rgba(255,255,255,0.85)` | `inset 3px 3px 8px rgba(0,0,0,0.6), inset -2px -2px 6px rgba(255,255,255,0.03)` |
| `--edge` (hairline that keeps relief legible on low-contrast displays) | `1px solid rgba(20,17,14,0.06)` | `1px solid rgba(252,250,238,0.05)` |
| Light source | top-left, 135 degrees, fixed across the app | same |

Rules: relief blur never exceeds 16px; opacity of the dark shadow never exceeds 0.14 on paper; a raised element on a raised element is not allowed (a card inside a card goes flat with a hairline). Hover on raised controls lifts by 1px and brightens the light shadow; press collapses to `--press`. `prefers-reduced-motion` removes the lift transition.

### 9.3 Sketch accents (the Japanese part), at the captain's "Bold" setting

- **Ma.** Page gutters stay 48px; the page header is at least 160px tall so the title sits in air; card padding 24 to 28px; section gaps 40px. Empty areas are allowed to stay empty.
- **Asymmetry.** The page header is left-weighted with the ridge drawing anchored top-right above the actions; the dashboard tile row is `1.15fr 1.15fr 1.15fr .8fr .8fr` (money tiles wider than count tiles); tables right-align money and leave the last column short.
- **Ink lines.** Dividers are 1px hand-drawn paths (inline SVG, slight wobble, `--sketch` colour) instead of CSS borders; the booking status pipeline is one drawn path with dots; table header rules and card footers are drawn once, not per row; the active tab carries a 2px ochre brush underline.
- **Sketch library (Bold).** Thin-line drawings in `--sketch` (`#3d3226` on paper, `#fcfaee` on ink) at full strength (opacity .9 on paper, .6 on ink), one per surface, never behind text:
  - *Ridge* (Ama Dablam silhouette with snow hatches): every page header, the sign-in card, the empty state.
  - *River* (a meandering double stroke with two or three eddies): section dividers between dashboard rows, card footers such as "Committed to future departures", the Tax year hub between numbered sections, and the confirmation and invoice paper layouts as a footer rule.
  - *Stupa and prayer flags* (Boudhanath dome with a flag line): Trips and bookings pages and the booking confirmation; *teahouse and trail* (a lodge roof with a switchback path): Departures and Expenses; *prayer wheel* (the mark in the logo, drawn larger): Settings and Business hub. These motifs answer the captain's "anything else that would fit"; the ship task draws them in the same 1 to 1.2px line and may add others from the website's photography (peaks, flags, stupas, trail, guides) but nothing outside that world.
  - Each motif is one `<symbol>` in a shared partial; the decorative scene budget is a ridge in the header and a river or scene lower down. Required empty-state ensos and zero-counter marks are outside that budget.
- **Enso.** A brush circle in `--seal` on every empty state and beside cleared, good-toned counters displaying `0` (0 overdue, 0 to review, queue is clear); formatted monetary zeroes are not cleared-queue counters.
- **Grain.** Visible paper grain from an SVG turbulence tile over `--paper`; the scheme-specific `--pb-grain` definitions in `app/assets/tailwind/application.css` own its colour and opacity. Removed on print.
- **Seal.** The orange appears as a small stamped square (6 to 8px radius) beside the active rail item and on the primary button; it is the one saturated thing on screen.

### 9.4 Type scale (app)

Gelasio for `.display`, `.stat-value`, empty-state headings, and money headlines; Montserrat for everything else. Tabular numerals on all money.

| Role | Size / line | Weight | Tracking |
|------|-------------|--------|----------|
| Page title | 40px / 1.1 (32px mobile) | 400 serif | -0.015em |
| Stat value | 34px / 1 | 400 serif, tabular | -0.01em |
| Card title | 16px / 1.3 | 600 sans | 0 |
| Body | 14.5px / 1.55 | 400 sans | 0 |
| Table | 13.5px / 1.45 | 400 sans, 500 on names | 0 |
| Label | 12.5px / 1.3 | 500 sans | 0.01em |
| Eyebrow | 13px / 1.3 | 500 sans, `--seal-text` | 0.02em, sentence case |
| Badge | 12px / 1 | 500 sans | 0.01em |
| Hint | 12px / 1.5 | 400 sans, `--ink-3` | 0 |

### 9.5 Radii and sizes

- Card 12px (brand); dashboard tile 16px (larger object, derived); control 10px; button 10px; badge 999px; seal mark 6px; rail item 10px.
- Rail 76px collapsed, 264px expanded (unchanged); content max width 1024px (unchanged); form column 672px (unchanged).
- Buttons 38px tall (32px small); inputs 40px; table rows 46px (40px compact).

### 9.6 Motion

- Website: 0.25 to 0.3s colour transitions on buttons, 0.55 to 0.6s image and card transforms, scroll-reveal sections (`.reveal`).
- App: hover and rail transitions accompany controls. Three entrance moments: the ridge draws on page load, the enso draws when rendered, and stat numbers settle in. All are removed under `prefers-reduced-motion`; no scroll reveals or per-card entrance animation. `app/assets/tailwind/application.css` owns the keyframes and timings.

### 9.7 Accessibility commitments

- Every text token in 9.1 meets 4.5:1 on its surface; `--ink-4` and `--seal` are never used for text under 18px.
- Focus: `2px solid --seal` ring at 2px offset on every interactive element, in both schemes; relief alone never indicates focus.
- Primary action: exactly one solid `--btn-primary` per view header; secondary actions are raised paper, never a second orange.
- Status: colour plus text plus icon on every badge and counter; bars carry `role="progressbar"` with values.
- Dark scheme is a first-class token set, not a filter; images and drawings are re-tinted per scheme.
- Hit targets 38px or larger; tables scroll inside their card on narrow screens.

### 9.8 Captain's conditions (2026-09-13)

The captain approved with two conditions, quoted exactly: "Include even more sketches with mountains and rivers that you had for a nicer touch or anything else that would fit. Also make the tabs and information intutive so that it is not only easy to understand but also engaging and fun."

The first condition is met by the sketch library in 9.3. The second becomes these rules:

- **Tabs.** Every tab shows a line icon from the sketch set, a sentence-case label, and a count where one exists ("Recurring · 1"); the active tab has the ochre brush underline and ink text, inactive tabs are `--ink-3`; hover lifts 1px and draws the underline in over 160ms. Tab groups sit directly under the page header with 24px of air, never inside a card.
- **Information.** Every table and card gets one plain-language caption line under its title saying what it shows and what to do ("Every disbursement, converted to USD, with its receipt. Click a row to open it."). Counters carry a word beside the number, bars carry the amount beside the percentage, badges carry words, and the booking pipeline names every step on the drawn line.
- **Engaging and fun, without noise.** Use the motion contract in 9.6. Delight comes from the drawings and the touch of the relief.
- The captain saw this interpretation in round 2 and kept it as shown; the ship task builds it without a further design review.

### 9.9 Logo and favicon (captain's round-2 request)

The captain annotated the prayer wheel drawing: "Use this as the logo of the app and also the favacon so that it is at the browser that I can see."

- **App logo.** The rail's 36px ochre tile (`app/views/shared/_logo.html.erb`) shows the prayer wheel line drawing in cream instead of the current mountain mark: the drum, axle and handle at 1.5px stroke, simplified to read at 20px (drop the script marks and tassel below 24px). The sign-in card shows the same drawing at 64px beside the PerfectBook wordmark.
- **Favicon.** Replace `public/icon.svg`, `public/icon.png` (and the apple-touch-icon) and `public/favicon.ico` with the prayer wheel on an ochre `#c96f1a` rounded square (6px radius at 32px), cream stroke, so the tab is recognisable at 16px; provide 16, 32, 180 and 512px renders. Set `<meta name="theme-color">` to `#fcfaee` for the paper scheme and `#14110e` for night.
- The drawing stays the one in the sketch library, so the logo and the Settings motif are the same shape at different sizes.

### 9.10 Shipped adjustments (implementation, 2026-09-13)

A runtime audit of rendered text against its composited background (every text node on the dashboard, expenses, booking, tax hub, settings, departures, calendar and business screens, both schemes, 1440px) found three token pairs under 4.5:1 once badges sat on tinted fills: paper `seal-text` and `good` text, and night `bad` text on a danger-tinted row. The shipped tokens are `--seal-text #9a520f`, `--good #3f6a2a` (paper) and `--bad #eb8a7f` (night text; marks stay `#e07160`). After the change the audit reports zero failures. The CSS scheme definitions own the shipped values; section 9.1 records the palette rationale.
