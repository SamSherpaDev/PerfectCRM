require "test_helper"
require_relative "../../db/migrate/20261005031551_reconcile_stored_template_policy_clauses"
require_relative "../support/quote_terms_test_helper"

class TemplatePolicyRefreshTest < ActiveSupport::TestCase
  include QuoteTermsTestHelper

  test "persisted renamed edited templates get clause patches without touching messages" do
    stale = "Your remaining balance of {{balance_due}} is due before we meet in Kathmandu."
    template = Template.create!(name: "Captain's renamed briefing", subject: "My subject", body: "Personal opening. #{stale} Personal ending.")
    client = Client.create!(name: "Synthetic", email: "synthetic@example.com")
    message = client.conversations.create!.messages.create!(direction: "out", status: "sent", to_addrs: client.email, subject: "Old accepted message", text_body: stale, template: template)
    custom = Template.create!(name: "Intentional wording", body: "Keep my exact personal words")
    ActiveRecord::Migration.suppress_messages { ReconcileStoredTemplatePolicyClauses.new.migrate(:up) }
    assert_equal "Personal opening. #{TemplatePolicyRefresh::BALANCE} Personal ending.", template.reload.body
    assert_equal "My subject", template.subject
    assert_equal stale, message.reload.text_body
    assert_equal "Keep my exact personal words", custom.reload.body
    assert_no_changes -> { template.reload.updated_at } do
      ActiveRecord::Migration.suppress_messages { ReconcileStoredTemplatePolicyClauses.new.migrate(:up) }
    end
  end

  test "new scheduled private and close-in quote contexts use actual amounts" do
    client = Client.create!(name: "Synthetic", email: "synthetic@example.com")
    [ [ "scheduled", 180, "$500.00" ], [ "private", 180, "$1,192.50" ], [ "scheduled", 90, "$3,975.00" ] ].each do |kind, days, expected|
      quote = Quote.create!(client: client, party_size: 1, valid_until: Date.current + 14, trip_name: "Synthetic journey")
      quote.lines.create!(description: "Synthetic", quantity: 1, unit_minor: 397_500)
      complete_quote_terms(quote, journey_kind: kind, days: days)
      assert quote.deliver!
      context = TemplateContext.for(client)
      assert_equal expected, context["deposit_due"]
      assert_equal QuoteTerms::VERSION, context["terms_version"]
      assert_equal (Date.current + days - 90).iso8601, context["balance_due_on"]
    end
  end

  test "existing booking uses its accepted schedule not new policy inference" do
    client = Client.create!(name: "Synthetic", email: "synthetic@example.com", perfectbook_contact_id: 123)
    booking = PerfectBook::Booking.create!(perfectbook_id: 124, perfectbook_contact_id: 123, start_date: Date.current + 150, synced_at: Time.current,
      payment_terms: { "payment_now_minor" => 75_000, "payment_due_on" => "2026-10-10", "balance_due_on" => "2027-01-10", "terms_version" => "Historical version" })
    context = TemplateContext.for(client)
    assert_equal "$750.00", context["deposit_due"]
    assert_equal "2027-01-10", context["balance_due_on"]
    assert_equal "Historical version", context["terms_version"]
    booking.update!(payment_terms: nil)
    context = TemplateContext.for(client)
    assert_nil context["deposit_due"]
    assert_nil context["balance_due_on"]
  end

  test "empty payment instructions cannot queue a reply or group message" do
    client = Client.create!(name: "Synthetic", email: "synthetic@example.com")
    assert_raises ActiveRecord::RecordInvalid do
      Outbound::Composer.call(owner: client, params: { subject: "Deposit", body: "Please pay [missing: deposit_due]" })
    end
  end
end
