require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class PipelineReviewTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup { sign_in }

  test "normal lead form accepts still talking" do
    post leads_path, params: { lead: { name: "Form traveler", source: "manual", status: "new", lost_reason: "" } }
    assert_response :redirect
    assert_nil Lead.find_by!(name: "Form traveler").lost_reason
  end

  test "invalid edit cannot persist a stage change or event" do
    lead = Lead.create!(name: "Traveler", source: "manual")
    assert_no_difference "ActivityEvent.count" do
      patch lead_path(lead), params: { lead: { status: "chatting", email: "invalid", lost_reason: "" } }
      assert_response :unprocessable_entity
    end
    assert_equal "new", lead.reload.status
  end

  test "lost still requires a reason and valid edits save together" do
    lead = Lead.create!(name: "Traveler", source: "manual")
    patch lead_path(lead), params: { lead: { status: "lost", lost_reason: "" } }
    assert_response :unprocessable_entity
    assert_equal "new", lead.reload.status
    patch lead_path(lead), params: { lead: { status: "chatting", name: "Renamed", lost_reason: "" } }
    assert_response :redirect
    assert_equal "chatting", lead.reload.status
    assert_equal "Renamed", lead.name
    assert_equal 1, lead.activity_events.where(kind: "stage_change").count
  end

  test "conversion review names the match and rejects a changed match" do
    client = Client.create!(name: "Existing traveler", email: "return@example.com", pipeline_stage: "post_trip")
    lead = Lead.create!(name: "Returning traveler", email: client.email)
    patch pipeline_move_path, params: { lead_id: lead.id, to: "won" }
    assert_redirected_to lead_path(lead)
    follow_redirect!
    assert_select "form[data-turbo-confirm*=?]", client.name
    assert_select "input[name=expected_client_id][value=?]", client.id.to_s
    post convert_lead_path(lead), params: { expected_client_id: "new" }
    assert_not lead.reload.converted?
    assert_equal "post_trip", client.reload.pipeline_stage
    post convert_lead_path(lead), params: { expected_client_id: client.id }
    assert_redirected_to client_path(client)
    assert_equal "won", client.reload.pipeline_stage
  end

  test "nudge opens rendered text and a prefilled email without touching the lead" do
    template = Template.create!(name: "Follow-up", purpose: "itinerary_follow_up",
      subject: "Your {{trip}}", body: "Hi {{first_name}}, checking in about {{trip}}.")
    lead = Lead.create!(name: "Tashi Sherpa", email: "tashi@example.com", trip_interest: "Annapurna")
    lead.update_columns(last_touch_at: 9.days.ago, last_activity_at: 9.days.ago)
    get pipeline_path
    path = lead_path(lead, template: template.id, nudge: 1)
    assert_select "a[href=?]", path, text: "Nudge"
    get path
    assert_response :success
    assert_select "h2", "Suggested message"
    assert_select "textarea", text: "Your Annapurna\n\nHi Tashi, checking in about Annapurna."
    assert_select "button", "Copy message"
    link = css_select("a").find { |node| node["href"].to_s.start_with?("mailto:") }
    assert_equal "mailto:tashi@example.com", link["href"].split("?").first
    query = URI.decode_www_form(link["href"].split("?", 2).last).to_h
    assert_equal "Your Annapurna", query["subject"]
    assert_equal "Hi Tashi, checking in about Annapurna.", query["body"]
    assert lead.reload.stale?
  end

  test "report counts each qualifying conversion once and preserves first-time history" do
    first = Lead.create!(name: "First visit", email: "traveler@example.com")
    client = first.convert_to_client!
    Lead.create!(name: "Return visit", email: client.email, source: "referral").convert_to_client!
    rate = Pipeline::Report.new.repeat_referral_rate
    assert_equal 2, rate[:converted]
    assert_equal 1, rate[:repeat]
    assert_equal 1, rate[:referral]
    assert_equal 1, rate[:qualifying]
    assert_equal 0.5, rate[:rate]
    get pipeline_path
    assert_select "p", text: /1 of 2 converted this year/
  end

  test "lost value remains a subtotal but leaves the active digest" do
    Lead.create!(name: "Lost inquiry", status: "lost", lost_reason: "price", expected_value_minor: 250_000)
    report = Pipeline::Report.new
    assert_equal({ "USD" => 250_000 }, report.value_by_stage["lost"])
    assert_equal 0, report.pipeline_total
    assert_match "0 open", report.digest_line
    assert_match "$0.00 in the pipeline", report.digest_line
  end

  test "client columns use mirrored totals and converted values with trip filters" do
    lead = Lead.create!(name: "Booked traveler", trip_interest: "Annapurna", expected_value_minor: 250_000,
      perfectbook_contact_id: 901)
    client = lead.convert_to_client!
    Client.create!(name: "Unrelated traveler")
    report = Pipeline::Report.new
    assert_equal({ "USD" => 250_000 }, report.value_by_stage["won"])
    PerfectBook::Booking.create!(perfectbook_id: 801, perfectbook_contact_id: 901, synced_at: Time.current, total_minor: 300_000, trip_name: "Everest")
    PerfectBook::Booking.create!(perfectbook_id: 802, perfectbook_contact_id: 901, synced_at: Time.current, total_minor: 100_000, trip_name: "Everest")
    assert_equal({ "USD" => 400_000 }, report.value_by_stage["won"])
    %w[Everest Annapurna].each do |trip|
      column = Pipeline::Board.new(trip: trip).columns.find { |entry| entry.stage == "won" }
      assert_equal [ client.id ], column.records.map(&:id)
      assert_equal({ "USD" => 400_000 }, column.values_by_currency)
    end
    assert_includes Pipeline::Board.new.trip_options, "Everest"
    client.update!(pipeline_stage: "post_trip")
    assert_equal({ "USD" => 400_000 }, report.value_by_stage["post_trip"])
    get pipeline_path(trip: "Everest")
    assert_select ".col-sum", text: "$4,000.00"
    assert_select "a", { text: "Unrelated traveler", count: 0 }
  end

  test "export preserves pipeline fields" do
    lead = Lead.create!(name: "Export inquiry", trip_interest: "Everest", expected_value_minor: 123_00,
      status: "lost", lost_reason: "dates", lost_note: "Next year")
    Client.create!(name: "Export client", pipeline_stage: "post_trip")
    get settings_export_path
    assert_response :success
    files = {}
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      while (entry = zip.get_next_entry)
        files[entry.name] = CSV.parse(zip.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
      end
    end
    row = files.fetch("leads.csv").find { |entry| entry["id"] == lead.id.to_s }
    assert_equal "Everest", row["trip_interest"]
    assert_equal "12300", row["expected_value_minor"]
    assert_equal "dates", row["lost_reason"]
    assert_equal "Next year", row["lost_note"]
    assert_equal lead.stage_changed_at.iso8601, row["stage_changed_at"]
    assert_equal lead.last_touch_at.iso8601, row["last_touch_at"]
    assert_equal "post_trip", files.fetch("clients.csv").first["pipeline_stage"]
  end


  test "mixed booking currencies stay separate on the board and report" do
    client = Client.create!(name: "Mixed currency traveler", perfectbook_contact_id: 903)
    { "NPR" => 14_000_000, "USD" => 250_000 }.each_with_index do |(currency, total), index|
      PerfectBook::Booking.create!(perfectbook_id: 900 + index, perfectbook_contact_id: 903,
        currency: currency, total_minor: total, synced_at: Time.current)
    end
    other = Client.create!(name: "Another traveler", perfectbook_contact_id: 904)
    PerfectBook::Booking.create!(perfectbook_id: 902, perfectbook_contact_id: other.perfectbook_contact_id,
      currency: "NPR", total_minor: 100_000, synced_at: Time.current)
    totals = { "NPR" => 14_100_000, "USD" => 250_000 }
    column = Pipeline::Board.new.columns.find { |entry| entry.stage == "won" }
    assert_equal totals, column.values_by_currency
    assert_equal totals, Pipeline::Report.new.value_by_stage.fetch("won")
    get pipeline_path
    assert_response :success
    assert_select ".col-sum", text: "NPR 141,000.00 · $2,500.00"
    assert_select "#numbers-heading", text: "Numbers"
    assert_select "span", text: "NPR 141,000.00 · $2,500.00", minimum: 2
    client.update!(pipeline_stage: "post_trip")
    assert_equal({ "NPR" => 14_000_000, "USD" => 250_000 }, Pipeline::Report.new.value_by_stage.fetch("post_trip"))
  end

end
