# Channel checks

The channels manager posts aggregate checks to PerfectCRM. The signed-in
`/channels` page selects each channel's latest snapshot by greatest check time,
then greatest record ID for ties. Earlier checks stay stored; there are no
trend charts or manual check forms.

## Request

`POST /api/v1/channels/snapshots`, `Content-Type: application/json`.
Authenticate with `Authorization: Bearer <owner-configured token>`.
The server reads `CHANNEL_CHECKS_TOKEN`; unset, empty or whitespace-only means
all requests are refused. There is no session, site-key or relay fallback.
See [operations](operations.md#channel-checks) for setup. Never put the token in
URLs, source control or reports.

```json
{
  "snapshot": {
    "channel": "youtube",
    "checked_at": "2026-09-30T03:00:00Z",
    "open_items": ["Review new comments", "Review video details"],
    "review_count": null,
    "review_rating": null,
    "follower_count": 230,
    "inquiries": 3
  }
}
```

- Required: `channel`, `checked_at`, `open_items`, inside the sole `snapshot`
  object. Unknown fields are rejected. Maximum JSON body: 4 KiB.
- Channel: `youtube`, `tiktok`, `tripadvisor`, `google_business_profile`,
  `instagram`, `facebook`, `google_ads`, `meta_ads`.
- Check time: ISO 8601 with an explicit `Z` or numeric offset, at most five
  minutes in the future. It is displayed in Pacific time.
- Review and follower counts: optional integer, 0 to 1,000,000,000, or null.
  Null or omission means unknown, not zero. Subscribers use `follower_count`.
- Organic inquiries: optional integer, 0 to 1,000,000,000, or null, for the
  six organic channels only. Count inquiries received on the channel itself
  (for example direct messages), aggregate only. Null or omission means unknown;
  zero means none. The latest check value is shown, without carrying forward
  an older known value or summing historical checks.
- `inquiries` is refused for `google_ads` and `meta_ads`, even if null.
  Snapshot-supplied spend and cost per inquiry are refused for every channel;
  paid spend uses the separate weekly request below.
- Rating: optional number from 1 to 5, stored to two decimal places, or null.
  A rating requires a positive review count.
- Open items: a unique array with at most eight short action lines, each at
  most 80 characters. Its length is the displayed open-item count. An empty
  array confirms no open actions; an unchecked channel is not shown as clear.

## Aggregate actions and privacy

Only these exact text lines are accepted, so names, emails, phones, handles,
addresses and other free text cannot be stored or shown:

- `Review new reviews`
- `Review new comments`
- `Check profile details`
- `Review scheduled posts`
- `Review video details`
- `Review campaign performance`
- `Check account access`
- `Check billing status`

A line represents an action category, not each individual review or comment.
Keep the details on the original channel. Never send customer data. The tracker
has no links to customers, messages, reviewers or individual accounts.

## Response

- `201`: `{ "id": 1, "channel": "youtube", "checked_at": "2026-09-30T03:00:00Z" }`.
  Each successful POST appends a snapshot, including repeat checks. A delayed
  check does not replace a newer check on the page.
- `401`: `{ "error": "unauthorized" }`, missing configuration or bad bearer.
- `415`: `{ "error": "json_required" }`.
- `413`: `{ "error": "too_large" }`.
- `400`: `{ "error": "invalid_json" }`.
- `422`: `{ "error": "invalid_snapshot" }`, optionally with a `fields` array
  of invalid field names. Submitted values are never echoed.

## Weekly spend request

This endpoint is for the channels manager's Monday check, an external agent
run that is not part of PerfectCRM and is configured separately with the same
`CHANNEL_CHECKS_TOKEN`. Nothing in PerfectCRM calls this endpoint. Until that
check posts, spend is entered on the Monday ads report page
(`/settings/weekly_report`) as before; the Monday email uses
whatever spend is already stored.

The external check should read last week's per-campaign USD spend from Google
Ads and Meta and post both channels before the Monday 7am Pacific email.
Post one channel and one complete week per request, including every campaign
for that channel and week.
Paid inquiries still come from CRM leads; checks cannot supply them.

`POST /api/v1/channels/spend`, `Content-Type: application/json`.
Use the same bearer authentication and `CHANNEL_CHECKS_TOKEN` as snapshots.
Missing or blank configuration refuses every request. No new credential is needed.

```json
{
  "spend": {
    "channel": "google_ads",
    "week_start": "2026-09-21",
    "campaigns": [
      { "campaign_name": "Nepal Search", "amount_dollars": "126.50" },
      { "campaign_name": "Nepal Groups", "amount_dollars": "0.00" }
    ]
  }
}
```

- The sole top-level field is `spend`. All fields shown are required; unknown
  fields at any level are rejected. Maximum JSON body: 16 KiB.
- Channel: `google_ads` or `meta_ads` only.
- Week: `YYYY-MM-DD`, a Monday in the last eight complete Pacific weeks.
  The current week in progress, future weeks and older weeks are refused.
- Campaigns: at least one. Use the ad platform's campaign name, matching the
  CRM lead's campaign exactly, including capitalization. Surrounding whitespace
  is stripped. Names are required and at most 160 characters after stripping.
- Amount: USD, zero or more, with at most two decimal places. A decimal string
  is recommended; JSON numbers are also accepted. No currency signs or commas.
- Aggregate campaign spend only. Never send customer names, emails, phones,
  addresses, lead records or other personal data. Request payloads are filtered
  from application parameter logs; errors never echo submitted values.

The whole request saves in one transaction through `AdSpend.record!`. An invalid
campaign saves nothing, including no replacements of existing amounts. Posting
again replaces the amount for the same week, channel and campaign without
adding another row. If a campaign appears more than once in a request, its last
amount wins and the response lists it once. Entries not mentioned stay unchanged;
the API never deletes. Settings manual entry and Remove remain available for
corrections.

### Weekly spend response

`201` returns the saved entries, including the normalized campaign name and USD
amount as a two-decimal string:

```json
{
  "entries": [
    { "channel": "google_ads", "week_start": "2026-09-21", "campaign_name": "Nepal Search", "amount_dollars": "126.50" },
    { "channel": "google_ads", "week_start": "2026-09-21", "campaign_name": "Nepal Groups", "amount_dollars": "0.00" }
  ]
}
```

`401`, `415`, `413` and `400` use the same error codes as snapshots.
`422` returns `{ "error": "invalid_spend" }`, optionally with a `fields` array
of invalid field names, never values.

## Weekly metrics

For Google Ads and Meta ads, spend, inquiries and cost per inquiry are read from `WeeklyReport::Summary`,
using the last complete Monday-to-Sunday Pacific week, exactly as the Monday
email report. Campaign rows aggregate using the report's existing missing-spend
rules; one active paid campaign without spend leaves channel spend and cost
unknown. Costs are also unknown with no inquiries. The page labels this period
separately from the last check time.

Google Ads and Meta ads use existing CRM source attribution for paid inquiries
and stored `AdSpend` entries for spend, entered on the Monday ads report page or received through
the weekly spend endpoint when the separately configured external check posts.
The email, Settings preview and Channels page all keep using the same
`WeeklyReport::Summary` calculation. Snapshots cannot supply paid inquiries,
spend or costs. The six organic
channels have no separate CRM lead sources: their inquiries come only from the
latest snapshot, labeled separately from the paid report period. Website form
inquiries are not guessed into an organic channel. Organic rows show inquiries,
reviews and followers; spend and cost per inquiry are omitted because these
channels carry no ad spend. The weekly channel-spend calculation is unchanged. Monthly source reporting and
conversion-link repair are described in [source reporting](source-reporting.md).

## Daily spend request

`POST /api/v1/channels/daily_spend`, JSON, with the same owner-configured Bearer
`CHANNEL_CHECKS_TOKEN`. This additive endpoint leaves the weekly contract intact.

```json
{"spends":[{"spent_on":"2026-10-01","source":"google_ads","campaign_id":"123456","campaign_name":"EBC","currency":"USD","amount_minor":1800}]}
```

One to 100 rows, max 64 KiB; these six required keys, plus optional `ad_id`
and `ad_name` for an ad breakdown. Date is an exact `YYYY-MM-DD` Pacific
calendar day in the last two years, strictly before today. Source is
`google_ads` or `meta_ads`; campaign ID/name max 160 characters; currency is a
three-letter uppercase code; amount is a nonnegative integer in minor units.
Every campaign/day includes explicit zero rows when genuinely zero. Stable
campaign ID, not name, is identity. Upsert replaces the same date/source/
campaign ID/ad ID/currency amount atomically; renamed campaigns and ads do not
split history. Omit both ad fields for a campaign total. For ad rows, `ad_id`
must be a nonblank string up to 200 characters; `ad_name` is optional, at most
200 characters, and requires `ad_id`. A campaign total and its ad rows are
independent amounts, never added together. Post the total even when also posting
ad detail; the report cannot assume that the supplied ads cover a whole campaign.
Returns `201 {"entries":N}`; malformed data is rejected atomically.

For example, post a campaign total and one ad's part of that total:

```json
{
  "spends": [
    {"spent_on":"2026-10-13","source":"meta_ads","campaign_id":"123456","campaign_name":"Nepal trips","currency":"USD","amount_minor":1800},
    {"spent_on":"2026-10-13","source":"meta_ads","campaign_id":"123456","campaign_name":"Nepal trips","ad_id":"789012","ad_name":"Everest video","currency":"USD","amount_minor":1200}
  ]
}
```

Monthly costs use campaign totals only and require every day through the report cutoff in each supplied
campaign currency. Missing days stay unavailable. No weekly proration, FX,
budget-as-spend or summing daily totals on top of weekly entries. Weekly reports
continue to use the existing weekly spend contract. The external channel check
must be updated separately to post exact daily rows; CRM does not fetch ad
platform spend or acquire tokens itself.

## Spend status

Both spend endpoints record `last_posted_at` on each successfully saved entry,
including an identical repost. A rejected request or rolled-back batch leaves
receipt times unchanged. Settings corrections use the same weekly write path.
The nullable field is not backfilled: older rows show their explicitly labeled
last change time and "receipt time unavailable". These timestamps describe
receipt, not the spend day/week, and do not come from channel-check times.
Source receipt history includes all stored entries, regardless of the selected
report period, including daily ad-detail posts. Coverage and represented dates
remain limited to the selected period; the latest weekly spend week is limited
to the selected week or earlier.

Spend status on Channels, the weekly screen and both Monday email formats,
monthly paid-source reporting, and cost per inquiry separates receipt time,
spend dates and selected-period coverage. Daily coverage reuses the inquiry-cost
reader's [identity and completeness rules](#cost-per-inquiry-page), including
unambiguous name-to-ID matching for additional monthly campaigns. Missing
campaign-days are shown per source. Ad-day gaps are separate and never fill
campaign totals.
Campaigns absent from both inquiries and spend in the selected period cannot
be discovered by this check. Unknown attribution still withholds cost ratios.

Daily spend is stale when any required campaign with a covered day has its
latest covered date more than two Pacific calendar days behind the cutoff.
The source shows the oldest of those latest dates only when every required
campaign has a covered day; otherwise it flags a campaign with no covered day.
That missing-campaign state does not suppress warnings for known stale campaigns.
Missing yesterday can be incomplete without being stale. Historical periods
use their own cutoff (the day after the selected last spend day); complete old
months do not turn stale with age. A newly posted backfill keeps its original
spend dates. Weekly coverage remains independent: fresh daily data never fills
a missing weekly entry. Weekly amounts remain USD; daily currencies stay separate.

## Cost per inquiry page

Open **Channels > Cost per inquiry** (`/channels/cost-per-inquiry`). Signed-in
access uses the same rules as Channels. The default is the last seven complete
Pacific days; the date selector accepts up to 31 complete days within the last
two years. The page shows only aggregate counts and campaign/ad labels and IDs.
It never renders contact names, emails, phones, messages, inquiry references,
click IDs, or raw metadata. No live ad API or production write is part of the page.

Website inquiries are `capture_channel=website_form`, plus legacy records with
no capture channel and either the `website_form:` external reference prefix or
the `website_form` source. Paid leads without website evidence do not count.
The received timestamp (creation timestamp only when missing) selects the
Pacific day, including daylight saving changes. Each Lead counts once; copies
on Clients are not counted. Lost, archived, and converted inquiries remain in
history. Test leads and leads linked to test clients are omitted. Spam, as
defined under [Leads](../README.md#leads), is excluded from genuine counts and
shown separately. A weak fit, lost status, or spam score alone is not a spam marking.
Here, genuine means not marked suspected spam, not independently verified.

Attribution uses the eligible, permission-allowed `last_non_direct_touch`
snapshot in `metadata.acquisition`; source, campaign, and ad come from that
same snapshot. Missing or denied snapshots stay unknown, never borrow first
touch or self-reported discovery. Legacy website records use their stored paid
source and `metadata.attribution`, with `campaign_name` as a fallback name.
Stable `campaign_id` is preferred. A name matches posted spend only if it
identifies exactly one campaign ID for that source in the selected period.
Ambiguous names stay in the unknown campaign bucket. Only an explicit `ad_id`
identifies an ad within its campaign; `utm_content`, click IDs, and creative
names alone are not treated as ad IDs. Other identifiable website sources are
shown together; missing source has its own bucket.

Daily source spend sums campaign totals only. A campaign or ad seen in the
selected period needs an exact spend row for each selected day and each supplied
currency, including zero-spend days. Missing spend stays **Unknown**; ad-only
rows never replace missing campaign totals. No weekly proration or currency
conversion. Amounts are minor units with two decimals, as in the existing spend
contract. Cost per inquiry divides exact spend by genuine inquiries and is
unknown with zero inquiries. Unknown-source inquiries make paid-source counts
uncertain; unknown-campaign inquiries make that source's known campaign counts
uncertain; missing ad IDs make that campaign's known ad counts uncertain. Those
rows show **Unknown**, matched counts, and unassigned counts, and withhold the
ratio. Unassigned counts overlap across potentially affected rows and must not
be added. The website summary is the exact genuine total.

This compares spend and inquiries received on the same day. It is not a click
cohort or a platform conversion count; earlier visits can produce later inquiries.
