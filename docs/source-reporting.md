# Source reporting handoff

PerfectBook is the money/traveler system of record. CRM reads the additive facts
listed in `docs/leads-intake.md`, preserving manual/date versus timestamp precision.
Cash event currency is authoritative (currently USD), even if an invoice has a
different currency label. Booked trip value retains the invoice currency. No FX,
recognized-revenue allocation, passport/visa/insurance/DOB data or new money
entry is introduced.

## Link review

PerfectBook currently validates the *format* of `crm_inquiry_ref`, not existence.
Its authenticated booking response therefore supplies evidence, not an automatic
identity claim. CRM sync checks the SH reference, exact PerfectBook contact link,
known trip and departure month/year. Every unvalidated returned reference stays a candidate until
reviewed. A unique binding survives an unavailable mirror. Trip review requires
an existing contact-linked inquiry and a reason; changes log the old link and
actor/time/evidence. Fix the PerfectBook reference too when replacing it.

Purchase eligibility requires an explicit/reviewed binding and an actual
`timestamp` first receipt. Date-only manual receipts are counted in business
reports, but held out of timestamped platform events. Balance payments never
create another Purchase. Browser Lead submission IDs stay unchanged. Previously
attempted/pulled legacy Purchases without booking IDs hold potentially already
reported receipts, rather than replaying them under a new ID. Genuinely later
first receipts remain eligible; old ad outcomes are not remapped or rewritten.

CRM provides `GET /api/v1/inquiries/:reference`, protected by a Bearer
`PERFECTBOOK_INQUIRY_TOKEN` configured separately from browser credentials.
It returns only the reference, exact PerfectBook contact IDs, trip title/interest,
and departure month/year; unknown references return 404 and failed auth 401.
PerfectBook must call this before storage in a separate sibling follow-up.
Until then, matching returned references still require captain review. Reviewed
links survive refreshes with unchanged reference/contact/trip/departure evidence.

## Operator checks before enabling exports

1. Enter the Meta dataset/token and Google feed password directly in Settings.
2. Accept each platform's applicable terms in the platform; confirm in CRM.
3. Create the three Google import actions and daily HTTPS upload schedule.
4. Read Google Uploads accept/reject diagnostics and Meta Events Manager
   received-event/dedup diagnostics. A CRM feed pull/HTTP success is not proof
   of attribution, acceptance or dedup. No real import was sent by this work.
5. Respect current sharing/measurement permission; missing legacy permission
   stays withheld. Confirm platform windows against current account settings.

## Monthly review

The default is reported discovery, with form testimony marked provisional.
Paid-performance costs use last non-direct observed source and stable campaign
ID, never a switch to testimony. First-observed is a third alternative. Missing
links stay in totals; tests/spam are held. Archived accepted inquiries remain in activity and cohort counts. Group traveler
counts are the booker's source. Legacy connected calls without an inquiry stay
unknown; copied client calls do not count twice. Undated paid mirrors are
disclosed across history, never assigned a month using refresh time.
Refunds use refund dates; cancelled
bookings do not silently disappear. The screen gives current active/inactive
status for paid-in-month bookings plus cancellations occurring this month.

Money is grouped by currency. Missing facts/unknown identity, incomplete daily
spend and unavailable mirrors remain visible. Source-level paid costs aggregate
complete campaign periods; one missing campaign keeps source cost unavailable.
Campaign detail is retained in the disclosure. Cohort conversion denominators
are only fully matured inquiries; pending inquiries are not failures. Recognized
revenue and unique returning travelers remain unavailable upstream.

Q-fit is the owner's hand judgment at inquiry. Platform qualification requires
current strong/possible fit and owner Chatting/Quoted move. Missing historical
Q-fit must not be backfilled from an AI score or stage change.

## Reviewed backfill and retention

Deterministic batches need their reviewed SHA256, actor and unchanged source
facts. Mirror refresh clocks are transport noise, not changed evidence.
Inventory separates invoice-currency booked value/legacy paid totals from the
agreed USD-ledger cash totals. Snapshots remain observations, inferred links stay
labelled, and imports never generate historical ad events.

The existing source-retention clock covers legacy snapshots, owner-fit and
link-review evidence. An actually paid inquiry binding uses the booked horizon
before client conversion; expiring source evidence does not delete its binding
or financial facts.

See README, **Monthly source reports and reviewed backfill**, for dry-run/review
commands. Production backfill/deployment and real platform verification belong
to the operator after review, not the implementation worker.

Paid monthly activity and spend use the same completed-day cutoff. Lifetime bookers
retain invoice currency and cash-event currency separately. Original-source lifetime
and direct referral values are separate alternatives under one disclosure. Original
source uses the earliest inquiry with an exact contact/client link; pre-inquiry acquisition is unknown.
Inventory includes metadata-key counts, Person/PerfectBook email duplicate groups,
and zero/one/multiple candidate counts for all bookings, including linked ones.
