require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class PipelineRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "board renders the trail, seven columns, cards, and numbers" do
    Lead.create!(name: "New ask", source: "google_ads", status: "new",
      trip_interest: "Everest Base Camp", expected_value_minor: 250_000, fit_score: 82, fit_band: "strong")
    Lead.create!(name: "Quiet one", source: "manual", status: "chatting").tap do |lead|
      lead.update_columns(last_touch_at: 9.days.ago, last_activity_at: 9.days.ago, updated_at: 9.days.ago)
    end
    Lead.create!(name: "Gone", source: "manual", status: "lost", lost_reason: "price")
    converted = Lead.create!(name: "Booked", source: "referral", status: "quoted")
    client = converted.convert_to_client!

    get pipeline_path
    assert_response :success
    assert_select "h1", "Pipeline"
    %w[New Chatting Quoted Nudged Won Post-trip Lost].each do |stage|
      assert_select ".col-name, .stage-row", text: stage
    end
    assert_select "article.kcard", minimum: 4
    assert_select "a", text: "New ask"
    assert_select ".kcard-trip", text: "Everest Base Camp"
    assert_select ".kcard", text: /Stale/
    assert_select "a", text: "Nudge"
    assert_select "#numbers-heading", text: "Numbers"
    assert_select "dt", text: /Asks by source/
    assert_select "a[href=?]", lead_path(Lead.find_by(name: "New ask"))
    assert_select "a[href=?]", client_path(client)
  end

  test "move advances a lead and records a stage event" do
    lead = Lead.create!(name: "Mover", source: "manual", status: "new")
    patch pipeline_move_path, params: { lead_id: lead.id, to: "chatting" }
    assert_redirected_to pipeline_path
    assert_equal "chatting", lead.reload.status
    assert lead.activity_events.exists?(kind: "stage_change")
  end

  test "move to lost without a reason reopens the sheet with an error" do
    lead = Lead.create!(name: "Fader", source: "manual", status: "chatting")
    patch pipeline_move_path, params: { lead_id: lead.id, to: "lost" }
    assert_redirected_to pipeline_path(lost_lead_id: lead.id)
    follow_redirect!
    assert_response :success
    assert_match(/reason/i, flash[:alert].to_s)
    assert_select "dialog#lost-sheet"
    assert_equal "chatting", lead.reload.status
  end

  test "move to lost with a reason sticks" do
    lead = Lead.create!(name: "Fader", source: "manual", status: "chatting")
    patch pipeline_move_path, params: { lead_id: lead.id, to: "lost", lost_reason: "dates", lost_note: "July only" }
    assert_redirected_to pipeline_path
    assert_equal "lost", lead.reload.status
    assert_equal "dates", lead.lost_reason
  end

  test "move to won opens conversion review" do
    lead = Lead.create!(name: "Winner", source: "manual", status: "quoted")
    patch pipeline_move_path, params: { lead_id: lead.id, to: "won" }
    assert_not lead.reload.converted?
    assert_redirected_to lead_path(lead)
  end

  test "converted leads refuse moves" do
    lead = Lead.create!(name: "Done", source: "manual", status: "new")
    lead.convert_to_client!
    patch pipeline_move_path, params: { lead_id: lead.reload.id, to: "chatting" }
    assert_redirected_to pipeline_path
    assert_match(/read-only/, flash[:alert].to_s)
  end

  test "clients move between won and post-trip" do
    client = Client.create!(name: "Traveler", source: "manual")
    patch pipeline_move_path, params: { client_id: client.id, to: "post_trip" }
    assert_redirected_to pipeline_path
    assert_equal "post_trip", client.reload.pipeline_stage
    assert client.activity_events.exists?(kind: "stage_change")
  end

  test "clients reject lead stages" do
    client = Client.create!(name: "Traveler", source: "manual")
    patch pipeline_move_path, params: { client_id: client.id, to: "chatting" }
    assert_redirected_to pipeline_path
    assert_equal "won", client.reload.pipeline_stage
  end

  test "filters narrow the board" do
    Lead.create!(name: "Ad lead", source: "google_ads", status: "new")
    Lead.create!(name: "Manual lead", source: "manual", status: "new")
    get pipeline_path(source: "google_ads")
    assert_response :success
    assert_select "a", text: "Ad lead"
    assert_select "a", { text: "Manual lead", count: 0 }
  end
end
