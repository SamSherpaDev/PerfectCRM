# Quote booking documents

New quote delivery uses `QuoteTerms` and the released files in
`config/booking_terms/SH-TC-2026-10-04/`. Never edit a released source or its
clause-refresh mapping. A later policy gets a new version directory.

## Before sending

Drafts can be incomplete. Sending requires scheduled/private classification,
trip dates, inclusions, a verified local operator legal name, explicit
trip-specific differences (`None` when applicable), and every disclosure field.
The captain selects **one** transaction-specific fund notice based on verified
facts, not residence alone. No operator, fund eligibility or bond coverage is
inferred. The LLC rider, filed signature and current security evidence must be
verified before filling that field. The app records staff-supplied facts; it is
not independent verification of the bond or legal eligibility. New sends stop
after the released bond term ends on March 7, 2027 until a verified new
disclosure version is available.

New payment schedules must match the master: $500 per person scheduled or 30%
private more than 90 days out, full payment at 90 days or fewer, balance date
start minus 90 days. A draft's deposit and date are still entered by the captain
and validated on send. The disclosed amount already paid is exact US dollars
without commas, never more than the quote total. It reduces payment requested
now and the remaining balance without counting the same dollars twice; this is
staff-supplied disclosure information, not a CRM payment ledger.
Custom journeys and catalog journeys without supplied departure dates have
editable start/end dates; dates supplied by a catalog departure take precedence. A sent
deposit quote crossing into the 90-day full-payment window needs a fresh quote
before acceptance; the delivered documents are not silently revised.

`terms_bundle` freezes the delivered master (only its operator placeholder is
filled), completed disclosure, itinerary, differences, versions and quote
reference. The disclosure is projected from the released form: booking fields
are populated, the unselected fund branch is removed, and paper receipt blanks
are replaced by electronic quote-acceptance information. The separate activity
release is not falsely described as attached to this quote bundle. SHA-256 is over the
UTF-8 result of `JSON.generate(terms_bundle)`. Emails carry the exact text files
and JSON; the PDF includes those texts. The public page renders the stored
bytes, not today's website. Delivered quote details, identity and lines cannot
be edited; revision/duplicate creates a draft without an accepted bundle.

Quote acceptance requires a checkbox and the delivered hash. It records
`accepted_at`, `accepted_terms_version` and `accepted_bundle_sha256` atomically
with the intake. Acceptance is not an activity release signature, newsletter
permission, payment authorization or a confirmed booking. Each adult's personal
release and payment-compliance checks remain PerfectBook's responsibility.

## Manual PerfectBook handoff

No automatic booking is created. The staff intake download and acceptance-notice
attachment contain JSON with `quote_reference`, trip/dates/party, USD total,
`deposit_minor` (the master deposit target), `paid_to_date_minor`,
`payment_now_minor`, `balance_due_minor`, `balance_due_on`, `accepted_at`,
`accepted_terms_version`, `accepted_bundle_sha256`, and the complete
`terms_bundle`. Import these **bytes and evidence**, not just a version label.
The booking-page URL passes reference/version/hash only; it cannot carry the
complete documents. PerfectBook must preserve the accepted bundle and perform
its own pre-collection disclosure, signer, schedule and payment gates.

Historical sent/accepted quotes are never backfilled. Their existing acceptance
path remains available and exports a null new-version bundle. Never label a
historical acceptance SH-TC-2026-10-04 without actual new acceptance.

## Operational templates and rollout

Before deploying the clause migration, firstmate should run the read-only
`bin/rails terms:template_inventory` against the intended database. Its output
contains IDs, state, hashes and known-clause counts, not message/customer text.
Review flagged customized text separately. The migration replaces exact known
stale clauses even in renamed/partly edited templates; unrelated text remains.
It does not rewrite sent/queued messages, drafts, quotes or bookings.

Without a mirrored booking, template context uses the newest unexpired delivered
quote for the owner and resolved recipient, including quotes from converted leads.
Unaccepted quotes must still have a current payment schedule. Other recipients
do not inherit that quote's payment instructions. This context supplies the
delivered amounts, remaining balance, due date and terms version.
For an existing mirrored booking, the remaining balance comes from PerfectBook's
`balance_due_minor`; the requested payment, due dates and terms version come
only from optional PerfectBook API `payment_terms`:

```json
{
  "payment_now_minor": 50000,
  "payment_due_on": "2026-10-10",
  "balance_due_on": "2027-01-01",
  "terms_version": "SH-TC-2026-10-04"
}
```

This is the booking's accepted schedule, including historical versions. Until
PerfectBook supplies it, missing values stay visible for manual review; they
are never replaced with $500 or a new due date. Outbound messages with missing
financial/version markers cannot queue. The sender must supply verified values
or remove the payment instruction. Receiving insurance documents does not
establish cover, and sensitive documents use PerfectBook's private upload path.
AI receives the delivered quote's master/version/differences labeled as belonging
only to that quote; every draft still requires human review.
