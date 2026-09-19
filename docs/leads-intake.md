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
A second open inquiry from the same email is a `400` validation with `{ "contact.email": "taken" }` - reply in the
existing thread instead.

Source derivation: `google_ads` on `gclid`/`gbraid`/`wbraid`, or
`utm_source=google` with a paid medium (`cpc`, `ppc`, `paid`); `meta_ads`
on `facebook`/`instagram`/`meta` with a paid medium; else `website_form`.
`campaign_name` copies `utm_campaign`. The reference is `SH-XXXX`.

Referral: `attribution.referral_code` is optional. The storefront sends the
advisor code from its `?ref=CODE` landing links here (six chars from
`ABCDEFGHJKMNPQRSTUVWXYZ23456789`, no I, L, O, 0, or 1). A code outside
that format is ignored as if no code was given; intake never rejects over
it. A valid code is stored on the lead, shown on the record, and carried
to the client at conversion so the referrer can be credited when the
booking is created in PerfectBook, which stays the system of record for
commissions.

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
