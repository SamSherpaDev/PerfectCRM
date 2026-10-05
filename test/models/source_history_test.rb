require "test_helper"

class SourceHistoryTest < ActiveSupport::TestCase
  setup { Current.user_email = nil }
  teardown { Current.reset }

  test "form testimony stays separate from clicks and original answer survives confirmation and correction" do
    lead = Lead.create!(name: "Source Example", source: "google_ads", metadata: { "attribution" => { "gclid" => "example" } })
    SourceAnswers.record!(lead, choice: "personal_referral", detail: "Alex", method: "website_form")
    original = lead.activity_events.where(kind: "source_answer").last
    assert_nil lead.source_confirmed_at
    assert_equal "website_form", original.metadata["recorded_by"]
    assert_equal "how-heard-v1", original.metadata["question_version"]
    Current.user_email = "operator@example.com"
    SourceAnswers.record!(lead, choice: "personal_referral", detail: "Alex")
    assert_not_nil lead.reload.source_confirmed_at
    assert_equal 2, lead.activity_events.where(kind: "source_answer").count
    assert_no_difference("ActivityEvent.count") { SourceAnswers.record!(lead, choice: "personal_referral", detail: "Alex") }
    assert_raises(ActiveRecord::RecordInvalid) { SourceAnswers.record!(lead, choice: "search", detail: "Google") }
    SourceAnswers.record!(lead.reload, choice: "search", detail: "Google", reason: "Remembered an earlier search")
    assert_equal "personal_referral", original.reload.metadata["answer_code"]
    assert_equal "Alex", original.metadata["detail"]
    assert_equal "google_ads", lead.source
    assert_equal "example", lead.metadata.dig("attribution", "gclid")
    correction = lead.activity_events.where(kind: "source_answer").last
    assert_equal "Remembered an earlier search", correction.metadata["correction_reason"]
    assert_equal "operator@example.com", correction.metadata["recorded_by"]
  end

  test "states and channels are typed and testimony is never inferred" do
    lead = Lead.create!(name: "Legacy", source: "meta_ads")
    assert lead.source_missing?
    assert_nil lead.reported_source_code
    %w[unsure declined not_asked].each do |choice|
      SourceAnswers.record!(lead, choice: choice, reason: "Asked again")
      assert_equal choice, lead.source_answer_state
    end
    lead.capture_channel = "facebook"
    assert_not lead.valid?
    lead.capture_channel = "phone"
    assert lead.valid?
    lead.save!
    SourceAnswers.record!(lead, choice: "event", detail: "Travel show")
    lead.reported_source_detail = "x" * 241
    assert_not lead.valid?
  end

  test "conversion preserves individual origins and referrals without replacing returning origin" do
    referrer = Client.create!(name: "Referrer")
    lead = Lead.create!(name: "Primary", email: "primary@example.com", source: "referral", referral_code: "KQ7X2D", referred_by_client: referrer)
    Current.user_email = "operator@example.com"
    SourceAnswers.record!(lead, choice: "personal_referral", detail: "Alex")
    companion = lead.people.create!(name: "Companion", email: "companion@example.com")
    SourceAnswers.record!(companion, choice: "instagram")
    client = lead.convert_to_client!
    assert_equal "personal_referral", client.reported_source_code
    assert_equal lead.source_confirmed_at, client.source_confirmed_at
    assert_equal referrer, client.referred_by_client
    assert_equal "KQ7X2D", client.referral_code
    assert_equal lead, client.origin_lead
    copied = client.people.first
    assert_equal "instagram", copied.reported_source_code
    assert_equal companion, copied.origin_person
    assert_equal companion.activity_events.where(kind: "source_answer").count, copied.activity_events.where(kind: "source_answer").count
    returning = Lead.create!(name: "Repeat", source: "google_ads", existing_client: client)
    SourceAnswers.record!(returning, choice: "search")
    assert_equal client, returning.convert_to_client!(expected_client_id: client.id)
    assert_equal "personal_referral", client.reload.reported_source_code
    assert_equal lead, client.origin_lead
    assert_equal "search", returning.reload.reported_source_code
  end

  test "returning-call timeline copies do not duplicate at conversion or after retry" do
    client = Client.create!(name: "Returning Booker")
    inquiry = Lead.create!(name: "New Ask", existing_client: client)
    SourceAnswers.record!(client, choice: "personal_referral", method: "website_form")
    SourceAnswers.record!(inquiry, choice: "search", method: "website_form")
    answer_id = inquiry.activity_events.where(kind: "source_answer").last.id
    key = SecureRandom.uuid
    call = CallLog.record!(inquiry, key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected")
    assert_equal 1, client.activity_events.where(kind: "call").count
    inquiry.convert_to_client!(expected_client_id: client.id)
    assert_equal 1, client.activity_events.where(kind: "call").count
    assert_no_difference("ActivityEvent.count") do
      CallLog.record!(inquiry, key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected")
    end
    assert_equal call.id, client.activity_events.where(kind: "call").last.metadata["from_lead_event_id"]
    assert_equal answer_id, call.metadata["source_answer_event_id"]
    assert_equal answer_id, client.activity_events.where(kind: "call").last.metadata["source_answer_event_id"]
  end

  test "calls without inquiry testimony never borrow another inquiry answer" do
    client = Client.create!(name: "Returning")
    SourceAnswers.record!(client, choice: "personal_referral", method: "website_form")
    first = Lead.create!(name: "First ask", existing_client: client)
    SourceAnswers.record!(first, choice: "search", method: "website_form")
    first.convert_to_client!(expected_client_id: client.id)
    inquiry = Lead.create!(name: "Second ask", existing_client: client)
    key = SecureRandom.uuid
    call = CallLog.record!(inquiry, key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected")
    assert_nil call.metadata["source_answer_event_id"]
    inquiry.convert_to_client!(expected_client_id: client.id)
    copied = client.activity_events.where(kind: "call").last
    assert_nil copied.metadata["source_answer_event_id"]
    assert_equal call.id, copied.metadata["from_lead_event_id"]
    assert_no_difference("ActivityEvent.count") do
      CallLog.record!(inquiry, key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected")
    end
  end

  test "personal referrals prohibit self links cycles and multiple referrers" do
    first = Client.create!(name: "First")
    second = Client.create!(name: "Second", referred_by_client: first)
    first.referred_by_client = first
    assert_not first.valid?
    first.referred_by_client = second
    assert_not first.valid?
    person = second.people.create!(name: "Companion")
    lead = Lead.new(name: "Both", referred_by_client: first, referred_by_person: person)
    assert_not lead.valid?
  end

  test "call double saves have one connected event and reminders do not log calls" do
    lead = Lead.create!(name: "Call Example")
    lead.tasks.create!(title: "Call", due_on: Date.current, done_at: Time.current)
    assert_empty lead.activity_events.where(kind: "call")
    SourceAnswers.record!(lead, choice: "search", method: "website_form")
    key = SecureRandom.uuid
    first = CallLog.record!(lead, key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected", duration: "42")
    second = CallLog.record!(Lead.find(lead.id), key: key, occurred_at: Time.current, direction: "outbound", outcome: "connected")
    assert_equal first.id, second.id
    assert_equal 1, lead.activity_events.where(kind: "call").count
    assert_equal lead.id, first.metadata["inquiry_id"]
    assert_equal 42, first.metadata["duration_seconds"]
    assert_equal lead.activity_events.where(kind: "source_answer").last.id, first.metadata["source_answer_event_id"]
    assert_raises(ArgumentError) { CallLog.record!(lead, key: key, occurred_at: Time.current, direction: "outbound", outcome: "booked") }
  end
end
