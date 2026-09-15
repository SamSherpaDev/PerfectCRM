# Website leads intake

How the storefront inquiry form and the automation ecosystem talk to
PerfectCRM. The normative contract is intake-spec.md sections 2, 4, 5 and 8
(shared with the PerfectBook storefront crew); this page documents what this
app actually serves.

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
"rate_limited" | "not_found" | "expired" | "converted" | "server" }`;
validation errors add a `fields` map from payload key to
`invalid` / `taken`.

## Browser mode (the storefront form)

CORS allow-origin: `https://www.sherpaholidays.com` and
`https://sherpaholidays.com` only. Methods `POST, OPTIONS`; headers
`Content-Type, X-Sherpa-Site-Key`; no credentials; preflight cached 24 h.

Every request sends the public site key (Settings → Automations) and an
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
(10 per IP per 10 minutes, 3 per email per hour — `429` with `Retry-After`);
filled honeypot (answered `202` with a synthetic reference, stored nowhere);
required fields (`contact.name` 2–120 chars, `contact.email` shaped with
MX/A records, `consent.contact: true`, `submission_id`); suspicion scoring
that only flags, never rejects.

Replaying the same `submission_id` returns `200` with the original
reference and writes nothing. A second open inquiry from the same email is
a `400` validation with `{ "contact.email": "taken" }` — reply in the
existing thread instead.

Source derivation: `google_ads` on `gclid`/`gbraid`/`wbraid`, or
`utm_source=google` with a paid medium (`cpc`, `ppc`, `paid`); `meta_ads`
on `facebook`/`instagram`/`meta` with a paid medium; else `website_form`.
`campaign_name` copies `utm_campaign`. The reference is `SH-XXXX`.

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

Unknown id: `404`. Older than 24 hours: `410`. Only provided fields change;
a "Details added by the visitor" note is appended once (repeating the same
body is one update). No email is sent; the lead page shows the answers.

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
curl -X POST https://perfectcrm.sherpaholidays.com/api/v1/leads/123/verdict \
  -H 'Content-Type: application/json' \
  -H "X-Sherpa-Signature: t=$T,v1=$SIG,kid=panda-ai" \
  -d '{ "fit_score": 82, "fit_band": "strong",
        "fit_reason": "Honeymoon, flexible dates", "status": "chatting" }'
# 200 { "reference": "SH-4K7Q", "status": "chatting", "fit_score": 82, "fit_band": "strong" }
```

`fit_score` 0–100, `fit_band` strong/possible/weak, `status` optional and
limited to `new`, `chatting`, `lost` — `quoted`, `nudged`, `won`, or a
converted lead are `422`. Every call lands on the lead timeline as an
`automation` event naming the caller.

## What happens after intake

- **Email copy.** A background job (5 retries over ~30 minutes) mails the
  inquiry to the Settings copy-to address (default
  `info@sherpaholidays.com`), Reply-To the visitor. Suspected spam prefixes
  the subject with `[check]`. Click IDs never enter the body. A mail
  failure never touches the lead.
- **Webhooks.** `lead.created` and `lead.details_added` are POSTed as
  `{ "event", "lead": { public fields plus attribution } }` to every URL in
  Settings, signed with the relay secret in the same `X-Sherpa-Signature`
  format, retried with backoff, and logged. An empty URL list disables them.
- **Spam.** Fast submits, link-stuffed messages, throwaway domains, and
  name-equals-email are scored, tagged `suspected_spam`, and counted —
  never rejected.
