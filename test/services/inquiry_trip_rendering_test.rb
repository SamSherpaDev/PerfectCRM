require "test_helper"

class InquiryTripRenderingTest < ActiveSupport::TestCase
  setup do
    Object.send(:remove_const, :TEMPLATES) if Object.const_defined?(:TEMPLATES)
    load Rails.root.join("db/seeds/templates.rb")
    @template = Template.find_by!(name: "First reply to a new inquiry")
    Setting.current.update!(sender_name: "Sam")
    @lead = Lead.create!(name: "Maya Test", email: "maya@example.test", source: "website_form",
      trip_title: "18-Day Everest Base Camp Premium Trek", received_at: Time.current)
  end

  test "website trip renders in every template through inquiry direct reply and group contexts" do
    contexts = [ TemplateContext.for(@lead),
      TemplateContext.for_reply(to: @lead.email.upcase, owner: @lead)[:context],
      TemplateContext.for_recipient(MergeBatch::Recipient.new(name: @lead.name, email: @lead.email)) ]
    contexts.each do |context|
      assert_equal @lead.trip_title, context["trip"]
      Template.all.select { |template| template.placeholders.include?("trip") }.each do |template|
        rendered = template.rendered(context)
        assert_includes "#{rendered[:subject]}\n#{rendered[:body]}", @lead.trip_title
        assert_not_includes rendered[:body], "[missing: trip]"
      end
    end
    assert_equal "Planning your #{@lead.trip_title}", @template.rendered(contexts.first)[:subject]
  end

  test "undecided and absent trips render naturally for inquiry and converted client sends" do
    [ "Not sure yet", "  not SURE yet  ", nil, " " ].each do |trip|
      @lead.update!(trip_title: trip)
      contexts = [ TemplateContext.for(@lead), TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context] ]
      client = Client.create!(name: @lead.name, email: @lead.email)
      @lead.update!(converted_client: client, converted_at: Time.current)
      contexts << TemplateContext.for_reply(to: client.email, owner: client)[:context]
      contexts << TemplateContext.for_recipient(MergeBatch::Recipient.new(name: client.name, email: client.email))
      contexts.each do |context|
        rendered = @template.rendered(context)
        assert_equal "Planning your Nepal trip", rendered[:subject]
        assert_includes rendered[:body], "help you plan your Nepal trip"
        assert_no_match(/\[missing: trip\]|Not sure yet/i, rendered[:body])
        assert_includes rendered[:body], "Would you be open to a short call?"
      end
      # Keep each conversion one-way; next iteration uses a fresh inquiry.
      @lead = Lead.create!(name: "Maya Test", email: "maya#{client.id}@example.test", source: "website_form")
    end
  end

  test "client sends use the latest matching converted inquiry without borrowing another traveler's trip" do
    client = @lead.convert_to_client!
    assert_equal @lead.trip_title, TemplateContext.for(client)["trip"]
    assert_equal @lead.trip_title, TemplateContext.for_reply(to: client.email, owner: client)[:context]["trip"]
    assert_equal @lead.trip_title, TemplateContext.for_recipient(
      MergeBatch::Recipient.new(name: client.name, email: client.email))["trip"]

    Lead.create!(name: "Other traveler", email: "other@example.test", source: "website_form",
      trip_title: "Other trip", converted_client: client, converted_at: Time.current, received_at: 1.hour.from_now)
    assert_equal @lead.trip_title, TemplateContext.for_reply(to: client.email, owner: client)[:context]["trip"]
    assert_equal "Nepal trip", TemplateContext.for_reply(to: "stranger@example.test", owner: client)[:context]["trip"]

    Lead.create!(name: client.name, email: client.email, source: "website_form", trip_title: "Not sure yet",
      converted_client: client, converted_at: Time.current, received_at: 2.hours.from_now)
    assert_equal "Nepal trip", TemplateContext.for_reply(to: client.email, owner: client)[:context]["trip"]
  end

  test "matching mirrored contacts and corrected addresses retain inquiry trip" do
    PerfectBook::Contact.create!(perfectbook_id: 9981, name: "Maya Mirror", email: @lead.email, synced_at: Time.current)
    assert_equal @lead.trip_title, TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context]["trip"]
    original = @lead.email
    @lead.update!(email: "corrected@example.test", email_redirects: { original => "corrected@example.test" })
    assert_equal @lead.trip_title, TemplateContext.for_reply(to: original, owner: @lead)[:context]["trip"]
  end

  test "manual interests override website titles but booking and quote truth win" do
    @lead.update!(trip_interest: "Private Nepal tour")
    assert_equal "Private Nepal tour", TemplateContext.for(@lead)["trip"]
    booking = PerfectBook::Booking.create!(perfectbook_id: 9982, perfectbook_contact_id: 9981,
      trip_name: "Booked trip", synced_at: Time.current)
    @lead.update!(perfectbook_contact_id: 9981)
    assert_equal "Booked trip", TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context]["trip"]
    booking.update!(unavailable_at: Time.current)
    quote = Quote.create!(lead: @lead, trip_name: "Quoted trip", status: :accepted, party_size: 1,
      valid_until: 7.days.from_now, terms_bundle: { "terms_version" => "test", "email" => @lead.email,
        "payment_now_minor" => 50000, "remaining_balance_minor" => 150000 })
    assert_equal quote.trip_name, TemplateContext.for(@lead)["trip"]
  end

  test "neutral trip does not mask payment fields or genuinely unknown placeholders" do
    @lead.update!(trip_title: nil)
    context = TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context]
    assert_equal "[missing: nickname] [missing: deposit_due] [missing: balance_due] [missing: payment_due_on]",
      TemplateRenderer.render("{{nickname}} {{deposit_due}} {{balance_due}} {{payment_due_on}}", context)
  end
end
