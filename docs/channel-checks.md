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
check posts, spend is entered in Settings as before; the Monday email uses
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
and stored `AdSpend` entries for spend, entered in Settings or received through
the weekly spend endpoint when the separately configured external check posts.
The email, Settings preview and Channels page all keep using the same
`WeeklyReport::Summary` calculation. Snapshots cannot supply paid inquiries,
spend or costs. The six organic
channels have no separate CRM lead sources: their inquiries come only from the
latest snapshot, labeled separately from the paid report period. Website form
inquiries are not guessed into an organic channel. Organic rows show inquiries,
reviews and followers; spend and cost per inquiry are omitted because these
channels carry no ad spend. Intake tracking, conversion exports and the weekly
report email behavior are unchanged.
