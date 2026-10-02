require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TemplateSubjectFallbackTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @lead = Lead.create!(name: "Tashi Sherpa", email: "tashi@example.com", source: "manual")
    @template = Template.create!(name: "Trip follow-up", purpose: :itinerary_follow_up,
      subject: "Your {{trip}}", body: "Hi {{first_name}}, checking in about {{trip}}.")
  end

  test "template use gives a lead without a trip a friendly subject and keeps body markers" do
    context = TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context]
    post use_template_path(@template, format: :json), params: { context: context }

    assert_response :success
    assert_equal "Planning your trip", response.parsed_body["subject"]
    assert_equal "Hi Tashi, checking in about [missing: trip].", response.parsed_body["body"]
    assert_equal 0, @template.reload.usage_count
  end

  test "picker JSON and HTML show a friendly subject without sample trip values" do
    get picker_templates_path(format: :json)
    assert_response :success
    row = response.parsed_body.find { |entry| entry["id"] == @template.id }
    assert_equal "Planning your trip", row["subject"]
    assert_equal "Hi [missing: first_name], checking in about [missing: trip].", row["body"]

    get picker_templates_path
    assert_response :success
    assert_select "li p", text: "Planning your trip"
  end

  test "pipeline and task nudges prefill a friendly subject for a lead without a trip" do
    task = @lead.tasks.create!(title: "Follow up", due_on: Date.current, template: @template)
    [ { nudge: 1 }, { task: task.id } ].each do |params|
      get lead_path(@lead), params: params.merge(template: @template.id)
      assert_response :success
      assert_select "input#message_subject[value='Planning your trip']"
      assert_select "textarea#message_body", text: "Hi Tashi, checking in about [missing: trip]."
    end
  end

  test "suggested task email draft uses the same subject fallback" do
    organization = Organization.create!(name: "Adventure Co.", email: "advisor@example.com")
    task = organization.tasks.create!(title: "Follow up", due_on: Date.current, template: @template)
    get organization_path(organization, task: task.id, template: @template.id)

    assert_response :success
    mailto = URI.parse(css_select('a[href^="mailto:"]').last["href"])
    query = URI.decode_www_form(mailto.opaque.split("?", 2).last).to_h
    assert_equal "Planning your trip", query["subject"]
    assert_equal "Hi Adventure, checking in about [missing: trip].", query["body"]
  end

  test "document nudge falls back with and without a template when the lead booking has no trip" do
    @lead.update!(perfectbook_contact_id: 7301)
    booking = PerfectBook::Booking.create!(perfectbook_id: 7302, perfectbook_contact_id: 7301,
      ref: "BK-7302", synced_at: Time.current, missing_count: 1,
      documents_json: { "travelers" => [ { "id" => 1, "first_name" => "Tashi",
        "documents" => [ { "type" => "visa", "status" => "missing" } ] } ] })
    Template.active.for_purpose(:document_request).update_all(archived_at: Time.current)
    documents = Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{first_name}}, for {{trip}} we need {{missing_documents}}.")

    [ true, false ].each do |with_template|
      documents.archive! unless with_template
      get document_nudge_path(booking_id: booking.id)
      assert_response :success
      assert_select "input[name='subject'][value='Planning your trip']"
      assert_select "textarea[name='body']", text: /Tashi: visa/
      assert_select "textarea[name='body']", text: /\[missing: trip\]/ if with_template

      get lead_path(@lead, nudge_booking_id: booking.id)
      assert_response :success
      assert_select "input#message_subject[value='Planning your trip']"
      assert_select "textarea#message_body", text: /Tashi: visa/

      booking.update!(trip_name: "Annapurna")
      assert_equal "Documents for Annapurna", TemplateContext.for_document_nudge(@lead, booking)[:subject]
      booking.update!(trip_name: nil)
    end
  end

  test "group merge uses a friendly subject for a lead without a trip and keeps body markers" do
    batch = MergeBatch.build(template: @template, recipient_lines: "Tashi Sherpa <#{@lead.email}>",
      context_for: ->(recipient) { TemplateContext.for_recipient(recipient) })

    assert batch.complete?
    assert_equal "Planning your trip", batch.messages.first.subject
    assert_equal "Hi Tashi, checking in about [missing: trip].", batch.messages.first.body
  end

  test "lead trip interest still personalizes the subject and body" do
    @lead.update!(trip_interest: "Annapurna")
    context = TemplateContext.for_reply(to: @lead.email, owner: @lead)[:context]
    post use_template_path(@template, format: :json), params: { context: context }

    assert_response :success
    assert_equal "Your Annapurna", response.parsed_body["subject"]
    assert_equal "Hi Tashi, checking in about Annapurna.", response.parsed_body["body"]
  end
end
