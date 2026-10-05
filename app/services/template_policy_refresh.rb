# frozen_string_literal: true

# Clause-level rollout, not a wholesale rewrite of captain-edited templates.
# These exact stale phrases came from both launch generations. Sent/queued
# messages and stored drafts are not touched. Unknown edits need human review.
class TemplatePolicyRefresh
  # Pin the rollout to its released source, independent of future quote versions.
  LIBRARY = Rails.root.join("config/booking_terms/SH-TC-2026-10-04/replacement-library.md").read.freeze
  ALTITUDE = LIBRARY.split("## ALTITUDE\n", 2).last.split("\n## ", 2).first.strip.freeze
  PRECEDENCE = LIBRARY.split("## PRECEDENCE\n", 2).last.split("\n## ", 2).first.strip.freeze
  DOCUMENTS = "Our Privacy Policy at https://www.sherpaholidays.com/policies/privacy-policy explains how we collect, use and share booking and traveler information, including information needed by overseas operators and authorities. We collect relevant passport, emergency-contact, health, dietary and mobility information where needed to arrange your journey. We share necessary information with the operators, service providers and authorities involved in your arrangements, including in the countries you visit. Please contact us for the private PerfectBook upload instructions; do not email sensitive documents.".freeze
  CONFIRMATION = "A booking is confirmed when the required payment and booking acceptance are received and we issue written confirmation. Private journeys also require a signed booking agreement.".freeze
  PAYMENT_REQUEST = "Payment requested now for {{trip}} on {{departure_dates}}: {{deposit_due}}, due {{payment_due_on}}, under your booking terms {{terms_version}}. Please read your delivered booking documents before paying.".freeze
  BALANCE = "Your remaining balance is {{balance_due}}, due {{balance_due_on}}, under the payment schedule you accepted. For new bookings under SH-TC-2026-10-04: The balance is due 90 days before departure. Your existing accepted schedule remains in effect.".freeze
  PATCHES = {
    "I planned the days with enough time to acclimatize and stops at the best viewpoints." => ALTITUDE,
    "I have shaped the days around good acclimatization and the views you should not miss." => ALTITUDE,
    "Take a look and let me know what you would like to change. We can adjust anything until it works for you." => PRECEDENCE,
    "Have a look and tell me what you would change. Nothing is fixed until it feels right to you." => PRECEDENCE,
    "A quick reminder that your {{trip}} seats for {{departure_dates}} are on hold until we receive your deposit of {{deposit_due}}." => PAYMENT_REQUEST,
    "A gentle note that your {{trip}} seats for {{departure_dates}} are held until your deposit of {{deposit_due}} arrives." => PAYMENT_REQUEST,
    "Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit arrives, your seats are confirmed." => CONFIRMATION,
    "Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit lands, everything else is confirmed." => CONFIRMATION,
    "A clear phone photo of each is fine. We store them securely in our booking system, not in email threads." => DOCUMENTS,
    "A clear phone photo of each is plenty. Everything is stored securely with our bookkeeping, never over email threads." => DOCUMENTS,
    "Your remaining balance of {{balance_due}} is due before we meet in Kathmandu." => BALANCE,
    "Once the deposit arrives, your seats are confirmed." => CONFIRMATION,
    "Once the deposit lands, everything else is confirmed." => CONFIRMATION,
    "We store them securely in our booking system, not in email threads." => DOCUMENTS,
    "Everything is stored securely with our bookkeeping, never over email threads." => DOCUMENTS,
    "If anything needs to change, like the pace, your room, or an extra rest day, tell your guide or reply to this email and I will take care of it." => "Tell your guide or reply to discuss any change in pace, room or rest days. We explain availability and any quoted cost before you decide.",
    "If anything needs adjusting \u2014 pace, rooms, an extra rest day \u2014 tell your guide or reply here and I will sort it." => "Tell your guide or reply to discuss any change in pace, room or rest days. We explain availability and any quoted cost before you decide."
  }.freeze

  def self.body(text)
    PATCHES.reduce(text.to_s) { |result, (old, replacement)| result.gsub(old, replacement) }
  end
end
