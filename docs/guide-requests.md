# Private Nepal guide requests v1

Source-only, **inactive by default**. This feature is not a campaign, subscription
system or inquiry. A request grants only permission to fulfill the requested guide.
The five-note series stays in the separate native Shopify Messaging pilot, with
fresh series-specific consent and suppression checks before every send.

## Browser contract

`POST /api/v1/guide_requests`, JSON:

```json
{"schema":"sherpa.guide-request.v1","email":"reader@example.com","source":"trip_quiz_result"}
```

Optional `honeypot` must be empty. No other fields accepted. No marketing, phone,
call or contact-consent field. Request time and guide edition are server-owned.
Use `Content-Type: application/json`, the existing public `X-Sherpa-Site-Key`, and
Origin `https://www.sherpaholidays.com` or `https://sherpaholidays.com`. OPTIONS
supports those origins. No session, new credential or relay mode. The public site
identifier is not a secret or proof of a human; IP/email throttling and a durable
per-address/per-edition reservation bound this public email-delivery surface.

202:

```json
{"schema":"sherpa.guide-receipt.v1","status":"accepted"}
```

This means durable request/outbox acceptance, **not delivery**. The same response
is returned for repeats, including already-attempted requests. There is no public
status endpoint, subscriber lookup or recipient enumeration. Show the approved
request-received copy only after 202. The visitor is not subscribed to anything.

Errors: 400 `bad_request` for malformed/non-object/over-2-KB JSON; 400 `validation`
with `fields` mapping invalid fields to `invalid` (`fields: unknown` for extras);
403 `forbidden` for an unauthorized browser; 429 `rate_limited` with `Retry-After`;
503 `unavailable` while inactive, prerequisites are missing, or persistence/queueing
fails. All error bodies use `{"error":"..."}`. No success UI on errors. Offer the
approved retry/info@ fallback. Client timeout suggestion: 15 seconds; an aborted
request has unknown acceptance. Retrying the same address is safe, but no automatic
retry loop or polling is needed. Do not fire protected inquiry/conversion events.

Rate limits use the existing database-backed limiter in a separate namespace:
10 per IP per 10 minutes, 3 per normalized address per hour. The address portion
of the limiter key is SHA-256, not plaintext. All request parameters are redacted
by the existing logging policy. The receipt stores only normalized email, fixed
edition, fixed source, timestamps, outbound message link and delivery-attempt time.
No page/referrer, subscriber state or new analytics event is collected.

## Existing mail path, bounded fulfillment

`GuideRequest.accept!` atomically reserves one D0 per normalized address and guide
edition and creates an unlinked Conversation plus queued Message. It never looks
up/creates a Lead, Person, Client, Shopify customer or marketing subscriber. There
is no inferred series enrollment, and an unsubscribed requester stays unsubscribed.
An existing subscriber needs separate fresh series consent at the site/Shopify step.

The existing `OutboundDeliveryJob` and `ClientMailer` use the existing info@ SMTP
settings. Guide messages bypass ordinary signature insertion/rendering so the exact
approved D0 signs once. From is `SherpaHolidays <info@sherpaholidays.com>`, Reply-To
is info@, and automatic-mail headers are set. Ordinary mail behavior and inquiry
routes/notifications/first replies are unchanged. The existing minute outbox sweep
recovers unattempted queued guide requests after an enqueue outage.

The receipt's durable claim permits **one SMTP attempt**, including overlapping
jobs. A transport error or uncertain acknowledgement is not retried. Repeated
requests never create a second guide message or replay a sequence, even later in
the same edition. Failed/uncertain cases need operator review in the existing mail
workflow; never reset the claim to force a resend. Queued, sending, sent and failed
Message states map to queued, uncertain, smtp_accepted and failed receipt states.
`sent` proves only the SMTP call returned successfully, not delivery/opening. A
process crash after claiming is uncertain and must not cause an automatic replay.
Turning the feature off before a queued job runs fails that message without sending.

## Approved content and activation hold

`config/private_nepal_guide/D0.txt` is the unmodified approved November 5 package
copy. Its review/timing/header block is excluded from outgoing mail; the body is
preserved, replacing only the approved final-PDF placeholder. The PDF is linked,
not attached or rebuilt. The approved original PDF/content package stays read-only.

`config/private_nepal_guide.yml` ships with every switch false and no PDF URL.
No activation or deployment follows from source merge. All of these remain owner
prerequisites, not facts established by local tests:

1. Main assembles one combined live-like owner preview of the site capture, exact
   D0/guide, separate fresh five-note consent and manual per-send suppression.
2. Marketmate/main supplies and verifies the final HTTPS PDF URL on the existing
   SherpaHolidays website or Shopify CDN, pointing to the exact approved PDF. The
   approved D0 currently has a placeholder. No placeholder or guessed link may send.
3. Owner verifies existing info@ SMTP and Reply-To identity/access using existing
   configuration, without a new service, secret or scope. Owner handles sign-in.
   Source tests do not establish an SMTP connection or a connected reply mailbox.
4. Assign an operator to monitor info@ replies and suppress all marketing, including
   the separate Shopify pilot/cold outreach, on an unsubscribe before the next send
   and within 10 business days. Keep the reply mechanism working for at least
   30 days after sending; no sign-in, payment or extra personal information. Pause
   notes on a reply/call/planning conversation. Do not alter service-reply permission
   or reactivate marketing because a guide was requested. Existing mail ingestion
   retains unread reply opt-outs; this code does not automate Shopify suppression.
5. The approved D0 contains the business postal address, commercial identification
   and reply `unsubscribe` footer. The footer's provider-link condition applies if
   a marketing send tool is used; this info@ SMTP path is not that tool. No invented
   unsubscribe URL is added. Keep Marketmate's wording; any copy question goes there.
6. Only the separately coordinated **one Shopify merchant test to info@** is
   authorized for the owner-preview workflow. This backend lane sends no real or
   test email and must not create a second test. Combined preview approval must be
   followed by separate explicit activation authorization. Only then may an
   authorized operator set the approval switches, final URL and enabled flag.

Missing URL, owner preview, reply handling, verified mailbox or correct existing
MAIL_FROM keeps intake unavailable and prevents queued delivery. Test SMTP rendering
uses the Rails test adapter/stubbed sender and synthetic records only. It establishes
source behavior, never deployment, actual delivery or Shopify consent/suppression.
