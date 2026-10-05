# Website leads intake

How the storefront inquiry form and the automation ecosystem talk to
PerfectCRM. This page owns the API contract served by this app.

Base URL: `https://perfectcrm.sherpaholidays.com`.

## Endpoints

| Method | Path | Auth | Success |
|---|---|---|---|
| `OPTIONS` | `/api/v1/leads/intake`, `/api/v1/leads/intake/details` | none | `204` + CORS headers |
| `POST` | `/api/v1/leads/intake` | site key or relay signature | `202`, replay `200` |
| `POST` | `/api/v1/leads/intake/details` | site key or relay signature | `200` |
| `POST` | `/api/v1/leads/:id/verdict` | relay signature only | `200` |

Bodies are `application/json`, max 32 KB. Error bodies are
`{ "error": "bad_request" | "forbidden" | "unauthorized" | "validation" |
"rate_limited" | "not_found" | "expired" | "converted" | "archived" | "server" }`;
validation errors add a `fields` map from payload key (or model attribute
for save failures) to `invalid` / `taken` / `required`. A verdict for a converted or
archived lead instead returns `{ "error": "validation", "fields": { "base": "converted" } }`
or `{ "base": "archived" }`.

## Browser mode (the storefront form)

CORS allow-origin: `https://www.sherpaholidays.com` and
`https://sherpaholidays.com` only. Methods `POST, OPTIONS`; headers
`Content-Type, X-Sherpa-Site-Key`; no credentials; preflight cached 24 h.

Every browser request sends the public site key (Settings → Automations) and an
`Origin` on the allowlist. Unknown key, bad `Origin`, or missing `Origin`:
`403 { "error": "forbidden" }`.

```bash
curl -X POST https://perfectcrm.sherpaholidays.com/api/v1/leads/intake \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://www.sherpaholidays.com' \
  -H 'X-Sherpa-Site-Key: sh_site_...' \
  -d '{
    "schema": "sherpa.inquiry.v2",
    "submission_id": "6f4b2f3c-0d7f-4a19-9d7e-4d0b2b0f7d8a",
    "placement": "landing",
    "contact": { "name": "Anna Lindqvist", "email": "anna@example.com", "phone_raw": "+1 415 555 0134" },
    "trip": { "handle": "private-nepal-tour", "title": "Private Nepal tour" },
    "message": "Two of us, first time in Nepal, thinking spring.",
    "consent": { "contact": true, "contact_at": "2026-09-14T18:06:40Z", "text_version": "2026-09-consent-v2" },
    "attribution": { "gclid": "Cj0K...", "utm_source": "google", "utm_medium": "cpc",
      "utm_campaign": "private-nepal-us-2027", "landing_url": "https://www.sherpaholidays.com/pages/private-nepal-tours?gclid=..." },
    "page": { "url": "https://www.sherpaholidays.com/pages/private-nepal-tours", "locale": "en-US" },
    "timing": { "started_at": "2026-09-14T18:05:58Z", "submitted_at": "2026-09-14T18:06:41Z" },
    "honeypot": "",
    "client": { "version": "inquiry-form@1.0.0" }
  }'
# 202 { "id": 123, "reference": "SH-4K7Q", "received_at": "..." }
```

Behavior, in order: schema/size check (`400`); auth (`403`); rate limits
(10 per IP per 10 minutes, 3 per email per hour - `429` with `Retry-After`);
filled honeypot (answered `202` with a synthetic reference, stored nowhere);
required fields (`contact.name` 2–120 chars, `contact.email` shaped with
MX/A records, `consent.contact: true`, nonblank `submission_id` up to 64 chars);
suspicion scoring that only flags, never rejects. DNS lookup failures fail open;
a completed lookup with no MX or A record rejects the address.

Replays pass authentication, rate limits, and required-field validation first.
Replaying the same `submission_id` returns `200` with the original
reference and re-enqueues pending notifications without replacing the inquiry.
A new `submission_id` from the same email opens a separate inquiry (`202`
with its own reference), so repeat visitors can ask about different trips.

Source derivation: `google_ads` on `gclid`/`gbraid`/`wbraid`, or
`utm_source=google` with a paid medium (`cpc`, `ppc`, `paid`); `meta_ads`
on `facebook`/`instagram`/`meta` with a paid medium; `trade_show` on
`utm_medium=event` (travel show booth links and QR codes); else `website_form`.
`campaign_name` copies `utm_campaign`. The reference is `SH-XXXX`.

Referral: `attribution.referral_code` is optional. The storefront sends the
advisor code from its `?ref=CODE` landing links here (six chars from
`ABCDEFGHJKMNPQRSTUVWXYZ23456789`, no I, L, O, 0, or 1). A code outside
that format after trimming whitespace and uppercasing is ignored as if no
code was given; intake never rejects over it. A valid code is stored on the
lead in normalized form; the original attribution remains in metadata.
For display, conversion, and booking use, see [Leads](../README.md#leads).

## Details follow-up (optional step two)

Posted after a successful send, with the same `submission_id`:

```bash
curl -X POST https://perfectcrm.sherpaholidays.com/api/v1/leads/intake/details \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://www.sherpaholidays.com' \
  -H 'X-Sherpa-Site-Key: sh_site_...' \
  -d '{
    "schema": "sherpa.inquiry.details.v1",
    "submission_id": "6f4b2f3c-0d7f-4a19-9d7e-4d0b2b0f7d8a",
    "trip": { "month": 4, "year": 2027, "timing_unknown": false, "budget_band": "4000_7000" },
    "party": { "size": 2 }
  }'
# 200 { "reference": "SH-4K7Q" }
```

Unknown id: `404`. Older than 24 hours: `410`. Converted lead: `422` with
`error: "converted"`; archived lead: `422` with `error: "archived"`. Details
have their own IP rate limit, with no email limit. Only provided fields
change; each change appends a "Details added by the visitor" note. Repeating
answers already stored makes no new note or notification. No email is sent;
the lead page shows the answers.

Month accepts integers 1-12, year 2020-2100, and party size 1-20.
Budget bands are defined by `Lead::BUDGET_BANDS`. These fields accept `null`
to clear them; `timing_unknown` accepts only `true` or `false`. Invalid field
values return `400`; model validation failures return `422`. Setting unknown
timing does not clear stored dates; see [Leads](../README.md#leads) for display behavior.

## Source database contract (v1)

Three independent facts are retained: what the person says first introduced
SherpaHolidays, the first eligible website touch actually observed, and the
latest inquiry visit. None overwrites either of the others. Existing `source`
and `campaign_name` remain compatibility groups, not self-reported testimony;
`last_touch_at` remains sales contact time, not a website visit. Legacy source
is not backfilled as an answer or a proven first touch.

### Exact optional question and stable answers

After the inquiry is saved: **How did you first hear about SherpaHolidays? (Optional)**
No source is preselected. Operators use the same codes, and can record the
answer immediately at the start of a call. Short detail is optional (240 chars).

| Visible answer | Code | Optional detail |
|---|---|---|
| A friend or family member | `personal_referral` | Who mentioned us? First name is enough. |
| Google or another search engine | `search` | Search engine; ad versus ordinary result only if remembered on the call. |
| Facebook | `facebook` | Paid/organic unknown unless separately supported. |
| Instagram | `instagram` | Paid/organic unknown unless separately supported. |
| YouTube | `youtube` | Video name/link on the call. |
| TikTok | `tiktok` | Account/video. |
| Pinterest | `pinterest` | Pin/article. |
| A travel show or event | `event` | Event name. |
| A travel advisor or another business | `advisor_partner` | Business/advisor name, optional code. |
| Google Maps or Tripadvisor | `maps_reviews` | Which one, if remembered. |
| An email from SherpaHolidays | `email_marketing` | No implied newsletter permission. |
| I already knew Sam, Gyalgin or SherpaHolidays | `existing_relationship` | Relationship or past trip, clarified on the call. |
| Somewhere else | `other` | Short explanation, including an AI assistant or article. |
| I don't remember | `unsure` | No forced follow-up. |

Internal answer states: `not_asked` (Not asked yet), `answered`, `unsure`, and
`declined` (Declined to answer). A source code of `unsure` uses state `unsure`;
other codes use `answered`. `not_asked` and `declined` have no code or detail.
The source answer is optional and never inferred from a click. `source_confirmed_at`
marks operator confirmation; original website answers stay in append-only
`ActivityEvent` history with `question_version=how-heard-v1`, answer/detail,
server recording time/actor, collection method, prior answer, correction reason
and optional evidence reference. A correction needs a reason. A form answer
cannot replace a later operator-confirmed answer.

Leads, clients and people have typed `reported_source_code`,
`reported_source_detail`, `source_answer_state`, `source_confirmed_at`,
`capture_channel`, `is_test`, `origin_lead_id`, and optional
`referred_by_client_id` / `referred_by_person_id`. Channel values:
`website_form`, `phone`, `email`, `social_dm`, `trade_show`, `in_person`, `other`.
Missing legacy channels remain null. Leads may explicitly link `existing_client_id`;
people copied at conversion link `origin_person_id`. New clients inherit the
inquiry's answer/referrals; returning inquiries do not replace a client's
lifetime origin. Companions retain their own answers, never the booker's.
Emails are match clues requiring operator review, not global identity proof.
Personal referrals cannot self-link or cycle, do not create marketable contacts,
and do not authorize contact with the referrer. Advisor codes remain separate;
commissions remain in PerfectBook. Tests are explicit, not inferred from source,
and excluded from inquiry reporting and ad exports.

### Additive browser payloads

Existing schemas, callers and success bodies remain unchanged. Intake and
post-send details accept an optional `acquisition` object. Details additionally
accept `source_answer`; it updates the existing submission within the same
24-hour window, locks, CORS/auth and rate limits. No second lead, conversion,
or ad outcome is created. Identical answers are no-ops. Converted and archived
inquiries stay protected. The authenticated CRM confirmation has no public
24-hour limit.

```json
{
  "acquisition": {
    "permission": {
      "state": "allowed", "measurement": true, "sharing": true,
      "opted_out": false, "observed_at": "2026-10-04T18:00:00Z"
    },
    "first_touch": {
      "observed_at": "2026-10-04T18:00:00Z", "utm_source": "instagram",
      "utm_medium": "social", "landing_url": "https://www.sherpaholidays.com/",
      "referrer": "https://www.instagram.com/"
    },
    "last_touch": {
      "observed_at": "2026-10-04T20:00:00Z", "utm_source": "google",
      "utm_medium": "cpc", "utm_campaign": "nepal", "campaign_id": "campaign-42",
      "gclid": "example-click", "landing_url": "https://www.sherpaholidays.com/pages/contact"
    },
    "last_non_direct_touch": {
      "observed_at": "2026-10-04T20:00:00Z", "utm_source": "google",
      "utm_medium": "cpc", "campaign_id": "campaign-42", "gclid": "example-click"
    },
    "submission_page": { "url": "https://www.sherpaholidays.com/pages/contact" }
  },
  "source_answer": {
    "code": "personal_referral", "detail": "A friend, Alex",
    "question_version": "how-heard-v1"
  }
}
```

Each touch is a complete snapshot, never merged click-by-click. Allowed keys:
`observed_at`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`,
`utm_term`, `campaign_id`, `ad_id`, `adset_id`, `gclid`, `gbraid`, `wbraid`,
`fbclid`, `landing_url`, `referrer`, `unknown_reason`. IDs/campaign strings max 200 chars;
URLs store host/path (path max 512), only allowlisted campaign queries,
no fragments, credentials, arbitrary queries or referrer paths. Click IDs are
separate columns of the snapshot, never retained inside URLs. Timestamps must
be ISO 8601 and cannot be future-dated beyond five minutes. The CRM records
classifier version `crm-source-v1` and permission recording time itself.
Normalized `source` is server-derived. Classifier v1 values are `google_ads`,
`meta_ads`, `trade_show`, `google`, `facebook`, `instagram`, `youtube`, `tiktok`,
`pinterest`, `search`, `email`, `referral`, `direct`, `unknown`. These observed
codes are independent of the self-reported list. `fbclid` alone does not prove paid Meta.
Paid source/campaign must come from the same snapshot. `first_touch` is immutable
on details updates while retained; last touch can reflect a genuine direct
return. Internal navigation is not new acquisition. No timestamp means unknown,
not direct. Missing reasons: `legacy_missing`, `not_asked`, `declined_permission`,
`no_detectable_referrer`, `unresolved_identity`, `unavailable`, `withdrawn`,
`consent_granted_late`. Do not backdate a click when permission is granted late.
Anonymous cross-device identity stitching and fingerprinting are not supported.

Permission states: `allowed`, `denied`, `unavailable`, `withdrawn`.
Touch persistence requires Shopify marketing processing permission and respects
sale/sharing opt-out and withdrawal; there is no analytics-cookie workaround.
Denied/unavailable/withdrawn or `opted_out: true` stores a missing reason instead
of marketing evidence. Withdrawal through details removes existing evidence.
Server ad exports require explicit allowed state plus `measurement: true`,
`sharing: true`, no opt-out, and no test/spam exclusion. Legacy records with
no permission snapshot are withheld, not silently treated as consented.
Contact consent, optional source testimony, newsletter subscriptions and
measurement/sharing permission are distinct. No messages, source details,
referrer identities, passport/visa/insurance/DOB/medical/emergency data enter ad
exports or this source database. Hashing contact facts is not anonymization.

### Calls, booking references, time and money

Connected calls are explicit `ActivityEvent(kind=call)` entries on an inquiry,
not task completion. Outcomes: `attempted`, `connected`, `voicemail`, `no_answer`;
direction inbound/outbound, occurrence time, optional duration, operator and
source-answer event reference. A stable per-save UUID is unique per inquiry;
a double save counts once. Client call logging requires selection of one of
that client's explicit inquiries. Copying a timeline on conversion retains the
original inquiry ID; count only inquiry-subject events for business call counts.

The shared booking reference is **`crm_inquiry_ref` = Lead.reference**, the
existing unique `SH-` plus four characters from `Lead.build_reference`, not the
submission UUID or PerfectBook contact ID. One primary inquiry per booking;
multiple bookings per inquiry. PerfectBook must validate the reference through
the trusted authenticated sibling integration, not trust a browser query alone.
Link edits need actor/date/evidence/reason. Booking binding and sync are later
work; no inference is upgraded to reviewed evidence in this task.

PerfectBook's additive booking API contract: `crm_inquiry_ref`,
`first_received_at`, `first_received_on`, `first_received_precision`
(`timestamp` / `date` / null), `receipts_minor`, `refunds_minor`,
`net_received_minor`, `traveler_count`, `cancelled_at`, and
`cash_events` containing `{id, kind: receipt|refund, occurred_at, occurred_on,
time_precision, amount_minor, currency}`. USD only in the agreed sibling
contract. Existing `total_minor`, `paid_minor`, `party_size`, `status`,
`currency`, and booking `source` (`manual`/`shopify`) retain their meaning.
Date-only money evidence must not be invented as an exact receipt timestamp.
Calendar months use `America/Los_Angeles`; timestamp wire values use ISO 8601
with offset/UTC. Money uses integer minor units and explicit currency; no FX
mixing or inferred recognized revenue. PerfectBook remains the money/traveler
system of record. Bookings/travelers are distinct IDs; group attribution is
labeled booker's source, not each companion's discovery. Repeat bookings do
not reacquire a person. Current weekly inference and both qualification counts
remain compatibility behavior until the separate binding/report tasks ship.

### Retention and access

Recommended bounded schedule: browser cookies 90 days (storefront task);
detailed click IDs/URLs at most 180 days after inquiry; unbooked source history
24 months after last substantive contact; booked-client discovery/relationship
history 7 years after last booking, reviewed annually. The scheduled
`SourceHistoryRetentionJob` enforces these bounds for source snapshots,
source/referral events and call logs, including archived records. Converted
clients without complete booking mirrors use the conservative seven-year
horizon until authoritative binding is available. The job does not delete CRM
contacts/correspondence or PerfectBook accounting/documents; whole-contact
and backup expiry belong to the separate privacy policy/deletion review.
De-identified source/month aggregates may be retained for long-term trends;
monthly aggregates are later work. No arbitrary 20-year identifiable tracker.

Access stays within existing signed-in operator authentication. Public callers
can only add optional testimony to their accepted submission under existing
window/auth limits, never confirm identity, bind bookings, set tests, authorize
commissions or overwrite client origins. Source corrections/deletions must cover
metadata, copied history and referral pointers, with deliberate backup expiry.
Customer-facing privacy text stays minimal and replaceable pending policy review.

## Relay mode (n8n, Panda AI, any server)

Signed with the relay secret (Settings → Automations, shown once at
rotation):

```
X-Sherpa-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, t + "." + raw body)>
```

`|now - t| > 300` or a mismatch: `401`. The `Origin` check is skipped.
An optional `,kid=<name>` names the caller (e.g. `kid=panda-ai`) for the
timeline. Intake and details accept relay mode; the verdict endpoint
requires it (`401` for browser credentials).

Rotate the relay secret to obtain its full value, copy it immediately, and
update server callers and webhook verifiers together. Rotation invalidates
the previous secret immediately. Site-key rotation likewise requires updating
the storefront form; there is no overlap period for either credential.

```bash
T=$(date +%s)
BODY='{...}'
SIG=$(printf '%s.%s' "$T" "$BODY" | openssl dgst -sha256 -hmac "$RELAY_SECRET" | sed 's/.* //')
curl -X POST https://perfectcrm.sherpaholidays.com/api/v1/leads/intake \
  -H 'Content-Type: application/json' \
  -H "X-Sherpa-Signature: t=$T,v1=$SIG,kid=n8n" \
  -d "$BODY"
```

## Verdicts (Panda AI scoring)

```bash
T=$(date +%s)
BODY='{"fit_score":82,"fit_band":"strong","fit_reason":"Honeymoon, flexible dates","status":"chatting"}'
SIG=$(printf '%s.%s' "$T" "$BODY" | openssl dgst -sha256 -hmac "$RELAY_SECRET" | sed 's/.* //')
curl -X POST https://perfectcrm.sherpaholidays.com/api/v1/leads/123/verdict \
  -H 'Content-Type: application/json' \
  -H "X-Sherpa-Signature: t=$T,v1=$SIG,kid=panda-ai" \
  -d "$BODY"
# 200 { "reference": "SH-4K7Q", "status": "chatting", "fit_score": 82, "fit_band": "strong" }
```

`fit_score` 0–100, `fit_band` strong/possible/weak, `status` optional and
limited to `new`, `chatting`, `lost` - `quoted`, `nudged`, `won`, or a
converted or archived lead are `422`. Reopening a lost lead also returns `422` if its
email or PerfectBook identity belongs to another open lead. Every successful
call saves its changes and an `automation` timeline event naming the caller
in one transaction. Failed calls do not add events.

A verdict with `"status":"lost"` must include `lost_reason`, using the same
values as the captain's loss form: `no_reply`, `price`, `dates`, `chose_another`,
`not_a_fit`, or `other`. Missing or invalid reasons return `400`, with
`error: "validation"`, `fields.lost_reason: "required"` or `"invalid"`, and an
explanatory `message`. For example:

```json
{ "status": "lost", "lost_reason": "not_a_fit", "fit_score": 20 }
```

Optional `lost_note` supplies the loss note. When omitted or blank, it defaults
to `Set by automation <kid>` (or `Set by automation relay` without a `kid`).
Actual status changes use the same transition rules as manual changes: they
reset `stage_changed_at`, record a `stage_change` event with actor `automation`,
and clear the loss reason and note when reopening a lead. The transition and
caller-specific automation event share one locked transaction. Score-only
verdicts and repeated statuses leave stage timing unchanged.

## What happens after intake

- **Email copy.** A background job mails the inquiry to
  `info@sherpaholidays.com`, Reply-To the visitor, From the app's `MAIL_FROM`
  (default `info@sherpaholidays.com`). Suspected spam prefixes
  the subject with `[check]`. Attribution metadata is omitted, and the
  displayed page URL strips `gclid`, `gbraid`, `wbraid`, and `utm_*` query
  parameters. A mail failure never touches the lead.
- **Webhooks.** `lead.created` and `lead.details_added` are POSTed as
  `{ "event", "lead": { public fields plus attribution } }` to the single URL in
  Settings, signed with the relay secret in the same `X-Sherpa-Signature`
  format, retried on failure, and logged. `LeadWebhookJob#webhook_payload`
  defines the payload fields; each attempt reads the current lead and current
  subscription settings. An empty URL disables delivery, completing pending
  webhook notifications without sending; enabling it later does not replay
  those completed notifications.
- **Spam.** Fast submits, link-stuffed messages, throwaway domains, and
  name-equals-email are scored, tagged `suspected_spam`, and counted -
  never rejected.

Notification intent is saved in `lead_notifications` in the same transaction
as the inquiry or details update. Intake and details replays re-check pending
rows. The outbox makes failed deliveries eligible for retry after five minutes.
In production, a recurring minute-by-minute drain enqueues eligible rows in
Solid Queue and recovers lost enqueues and expired delivery claims.
Delivery is at least once: a crash after sending but before recording completion
can resend a notification. Each webhook attempt remains in the delivery log.
Rate-limit admission uses a primary-database transaction shared across workers.
