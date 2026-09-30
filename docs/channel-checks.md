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
- Channel: `youtube`, `tripadvisor`, `google_business_profile`, `instagram`,
  `facebook`, `google_ads`, `meta_ads`.
- Check time: ISO 8601 with an explicit `Z` or numeric offset, at most five
  minutes in the future. It is displayed in Pacific time.
- Review and follower counts: optional integer, 0 to 1,000,000,000, or null.
  Null or omission means unknown, not zero. Subscribers use `follower_count`.
- Organic inquiries: optional integer, 0 to 1,000,000,000, or null, for the
  five organic channels only. Count inquiries received on the channel itself
  (for example direct messages), aggregate only. Null or omission means unknown;
  zero means none. The latest check value is shown, without carrying forward
  an older known value or summing historical checks.
- `inquiries` is refused for `google_ads` and `meta_ads`, even if null.
  Check-supplied spend and cost per inquiry are refused for every channel.
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

## Weekly metrics

For Google Ads and Meta ads, spend, inquiries and cost per inquiry are read from `WeeklyReport::Summary`,
using the last complete Monday-to-Sunday Pacific week, exactly as the Monday
email report. Campaign rows aggregate using the report's existing missing-spend
rules; one active paid campaign without spend leaves channel spend and cost
unknown. Costs are also unknown with no inquiries. The page labels this period
separately from the last check time.

Google Ads and Meta ads have existing CRM source attribution and Settings ad
spend. Checks cannot supply or overwrite their weekly metrics. The five organic
channels have no separate CRM lead sources: their inquiries come only from the
latest snapshot, labeled separately from the paid report period. Website form
inquiries are not guessed into an organic channel. Organic rows show inquiries,
reviews and followers; spend and cost per inquiry are omitted because these
channels carry no ad spend. Intake tracking, conversion exports and the weekly
report email behavior are unchanged.
