require "test_helper"
require "rake"

class LeadPhoneBackfillTest < ActiveSupport::TestCase
  test "backfill repairs encrypted blank phones on explicit contacts and is idempotent" do
    lead = Lead.create!(name: "Synthetic Booker", email: "booker@example.com", phone_raw: "(415) 555-0134")
    primary = lead.people.create!(name: "Synthetic Booker", email: lead.email)
    companion = lead.people.create!(name: "Synthetic Companion", email: "companion@example.com")
    client = lead.convert_to_client!
    # Represents clients converted before raw phone preservation was shipped.
    client.update_columns(phone_raw: nil)

    present = Lead.create!(name: "Already recorded", phone: "+14155550199", phone_raw: "4155550134")
    invalid = Lead.create!(name: "Unparseable", phone_raw: "call reception")
    invalid_client = invalid.convert_to_client!
    invalid_client.update_columns(phone_raw: nil)
    Lead.create!(name: "No phone")

    result = Leads::PhoneBackfill.call
    assert_equal 1, result[:leads_updated]
    assert_equal 2, result[:clients_updated] # Includes retaining unparseable raw.
    assert_equal 2, result[:people_updated]
    assert_equal 1, result[:unparseable]
    [ lead, client, primary, client.people.find_by(email: lead.email) ].each do |record|
      assert_equal "+14155550134", record.reload.phone
      assert_not_includes record.attributes_before_type_cast["phone"], "+14155550134"
    end
    assert_nil companion.reload.phone
    assert_nil client.people.find_by(email: companion.email).phone
    assert_equal "(415) 555-0134", lead.phone_raw
    assert_equal lead.phone_raw, client.phone_raw
    assert_not_includes client.attributes_before_type_cast["phone_raw"], lead.phone_raw
    assert_equal "+14155550199", present.reload.phone
    assert_nil invalid.reload.phone
    assert_equal "call reception", invalid_client.reload.display_phone
    assert lead.reload.converted?

    assert_equal({ leads_updated: 0, clients_updated: 0, people_updated: 0, unparseable: 1 }, Leads::PhoneBackfill.call)
  end

  test "present client and person phones are never overwritten and unrelated emails are not matched" do
    lead = Lead.create!(name: "Synthetic Booker", email: "known@example.com", phone_raw: "14155550134")
    person = lead.people.create!(name: "Synthetic Booker", email: lead.email, phone: "+14155550198")
    client = lead.convert_to_client!
    client.update!(phone: "+14155550199")
    other = Client.create!(name: "Unrelated", email: "unrelated@example.com")
    unrelated_person = other.people.create!(name: "Similar email", email: lead.email)

    Leads::PhoneBackfill.call
    assert_equal "+14155550199", client.reload.phone
    assert_equal "+14155550198", person.reload.phone
    assert_equal "+14155550198", client.people.find_by(email: lead.email).phone
    assert_nil other.reload.phone
    assert_nil unrelated_person.reload.phone
  end

  test "returning inquiry fills a blank client phone but preserves existing phones" do
    client = Client.create!(name: "Returning", email: "returning@example.com")
    lead = Lead.create!(name: client.name, email: client.email, phone: "+14155550134", phone_raw: "415-555-0134")
    assert_equal client, lead.convert_to_client!
    assert_equal "+14155550134", client.reload.phone
    assert_equal "415-555-0134", client.phone_raw
    next_lead = Lead.create!(name: client.name, email: client.email, phone: "+14155550199", phone_raw: "4155550199")
    next_lead.convert_to_client!
    assert_equal "+14155550134", client.reload.phone
    assert_equal "415-555-0134", client.phone_raw
  end

  test "rake task prints only counts" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("leads:backfill_phones")
    Lead.create!(name: "Synthetic", phone_raw: "415.555.0134")
    output, error = capture_io { Rake::Task["leads:backfill_phones"].execute }
    assert_empty error
    assert_equal({ "leads_updated" => 1, "clients_updated" => 0, "people_updated" => 0, "unparseable" => 0 }, JSON.parse(output))
    assert_not_includes output, "415"
  end
end
