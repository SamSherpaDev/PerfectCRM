require "test_helper"

class AdConversionsTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass)
      return code.start_with?("2") if klass == Net::HTTPSuccess

      super
    end
  end

  class FakeHttp
    attr_reader :requests
    attr_accessor :code, :body

    def initialize(code, body)
      @code = code
      @body = body
      @requests = []
    end

    def use_ssl=(_); end
    def open_timeout=(_); end
    def read_timeout=(_); end

    def request(req)
      @requests << req
      FakeResponse.new(@code, @body)
    end
  end

  setup do
    @now = Time.zone.parse("2026-10-12 10:00")
    travel_to @now
    @settings = Setting.current
    @settings.update!(meta_dataset_id: "123456789012345", meta_access_token: "EAAB-secret-token")
  end

  def ad_lead(attribution: { "gclid" => "Cj0K-click" }, **attrs)
    lead = Lead.create!({
      name: "Anna Lindqvist", email: "Anna.Lind@Gmail.com", phone: "+14155550134",
      source: "google_ads", external_ref: "website_form:sub-#{SecureRandom.hex(4)}",
      received_at: @now - 2.days,
      metadata: {
        "attribution" => attribution,
        "page" => { "url" => "https://www.sherpaholidays.com/pages/everest-base-camp" },
        "user_agent" => "Mozilla/5.0 Test"
      }
    }.merge(attrs))
    at = attrs[:stage_changed_at] || @now
    verdict(lead, lead.fit_band, at: at) if lead.fit_band.present?
    travel_to(at) { Leads::Transition.call(lead, to: lead.status) } if attrs[:status].in?(%w[chatting quoted nudged])
    lead
  end

  def verdict(lead, band, at: @now)
    lead.update!(fit_band: band)
    lead.activity_events.create!(kind: "automation", summary: "AI verdict", occurred_at: at,
      metadata: { "fit_band" => band })
  end

  def with_meta(code: "200", body: { "events_received" => 1 }.to_json)
    fake = FakeHttp.new(code, body)
    Net::HTTP.stub(:new, ->(*_) { fake }) { yield fake }
  end

  test "leads without a click ID are never recorded" do
    lead = ad_lead(attribution: { "utm_source" => "google", "utm_medium" => "cpc" })
    assert_empty AdConversions.record!(lead, now: @now)
    assert_equal 0, AdConversion.count
  end

  test "archived, spam, and not-a-fit leads are never recorded" do
    archived = ad_lead(archived_at: @now)
    spam = ad_lead
    spam.update!(tag_list: Lead::SUSPECTED_SPAM_TAG)
    unfit = ad_lead(status: "lost", lost_reason: "not_a_fit")
    [ archived, spam, unfit ].each { |lead| assert_empty AdConversions.record!(lead.reload, now: @now) }
  end

  test "the lead event reuses the submission id and waits for Meta only" do
    lead = ad_lead
    rows = AdConversions.record!(lead, now: @now)
    assert_equal [ "lead" ], rows.map(&:event)
    row = rows.first
    assert_equal lead.external_ref.delete_prefix("website_form:"), row.event_id
    assert_equal "pending", row.meta_status
    assert_not row.google
    assert_equal 300_00, row.value_minor
  end

  test "qualified needs a strong or possible verdict and the owner's chatting or quoted" do
    lead = ad_lead(fit_band: "weak", status: "chatting")
    assert_equal %w[lead], AdConversions.record!(lead, now: @now).map(&:event)

    verdict(lead, "possible")
    rows = AdConversions.record!(lead, now: @now)
    assert_equal %w[qualified], rows.map(&:event)
    assert rows.first.google
    assert_equal "sh-lead-#{lead.id}-qualified", rows.first.event_id
    assert_equal 1_000_00, rows.first.value_minor
  end

  test "owner fit edits before the sweep prevent qualification without retracting recorded outcomes" do
    lead = ad_lead(fit_band: "strong")
    lead.update!(fit_band: "weak")
    Leads::Transition.call(lead, to: "chatting")
    with_meta { AdConversions::ExportJob.perform_now(now: @now) }
    assert_equal %w[lead], lead.ad_conversions.pluck(:event)

    lead.update!(fit_band: "possible")
    with_meta { AdConversions::ExportJob.perform_now(now: @now) }
    qualified = lead.ad_conversions.find_by!(event: "qualified")
    assert_equal "sent", qualified.meta_status
    lead.update!(fit_band: "weak")
    with_meta { AdConversions::ExportJob.perform_now(now: @now) }
    assert_equal "sent", qualified.reload.meta_status
    assert_equal 1, lead.ad_conversions.where(event: "qualified").count

    other = ad_lead(fit_band: "strong", status: "chatting")
    other.update!(fit_band: "weak")
    assert_equal %w[lead], AdConversions.record!(other).map(&:event)
  end

  test "each outcome is recorded once even when the status moves back and forth" do
    lead = ad_lead(fit_band: "strong", status: "quoted")
    assert_equal %w[lead qualified quote], AdConversions.record!(lead, now: @now).map(&:event)
    lead.update!(status: "chatting")
    lead.update!(status: "quoted")
    assert_empty AdConversions.record!(lead, now: @now)
    assert_equal 3, lead.ad_conversions.count
  end

  test "a paid PerfectBook booking reports the margin share of its total" do
    @settings.update!(ad_booking_value_percent: 35)
    lead = ad_lead(perfectbook_contact_id: 77)
    PerfectBook::Booking.create!(perfectbook_id: 9001, perfectbook_contact_id: 77, status: "cancelled",
      paid_minor: 50_000, total_minor: 800_000, synced_at: @now)
    assert_not_includes AdConversions.record!(lead, now: @now).map(&:event), "booked"

    PerfectBook::Booking.create!(perfectbook_id: 9002, perfectbook_contact_id: 77, status: "deposit_received",
      paid_minor: 50_000, total_minor: 700_000, synced_at: @now)
    row = AdConversions.record!(lead, now: @now).find { |r| r.event == "booked" }
    assert_equal 245_000, row.value_minor
    assert_equal "Purchase", row.meta_event_name
  end

  test "Meta receives hashed user data, fbc from the landing URL, and the event id" do
    lead = ad_lead(attribution: {
      "landing_url" => "https://www.sherpaholidays.com/pages/ebc?fbclid=IwAR-abc&utm_source=facebook",
      "first_seen_at" => "2026-10-10T09:00:00Z"
    })
    row = AdConversions.record!(lead, now: @now).first
    with_meta do |fake|
      assert_equal :sent, AdConversions.deliver_meta!(row, settings: @settings, now: @now)
      request = fake.requests.first
      assert_equal "/v24.0/123456789012345/events", request.path
      body = JSON.parse(request.body)
      assert_equal "EAAB-secret-token", body["access_token"]
      event = body["data"].first
      assert_equal "Lead", event["event_name"]
      assert_equal row.event_id, event["event_id"]
      assert_equal "website", event["action_source"]
      assert_equal "https://www.sherpaholidays.com/pages/everest-base-camp", event["event_source_url"]
      user = event["user_data"]
      assert_equal [ Digest::SHA256.hexdigest("anna.lind@gmail.com") ], user["em"]
      assert_equal [ Digest::SHA256.hexdigest("14155550134") ], user["ph"]
      assert_equal [ Digest::SHA256.hexdigest(lead.id.to_s) ], user["external_id"]
      assert_equal "fb.1.#{Time.utc(2026, 10, 10, 9).to_i * 1000}.IwAR-abc", user["fbc"]
      assert_equal "Mozilla/5.0 Test", user["client_user_agent"]
      assert_equal({ "value" => 300.0, "currency" => "USD" }, event["custom_data"])
    end
    row.reload
    assert_equal "sent", row.meta_status
    assert_equal 1, row.meta_attempts
    assert_nil AdConversions.deliver_meta!(row, settings: @settings, now: @now), "sent rows never resend"
  end

  test "a Meta failure is kept with its reason and retried with a growing wait" do
    lead = ad_lead
    row = AdConversions.record!(lead, now: @now).first
    error = { "error" => { "message" => "Invalid OAuth access token." } }.to_json
    with_meta(code: "400", body: error) do
      assert_equal :failed, AdConversions.deliver_meta!(row, settings: @settings, now: @now)
    end
    row.reload
    assert_equal "failed", row.meta_status
    assert_equal "HTTP 400: Invalid OAuth access token.", row.meta_error
    assert_not_includes row.meta_error, "EAAB"

    row.update_column(:updated_at, @now)
    assert_nil AdConversions.deliver_meta!(row, settings: @settings, now: @now + 30.minutes)
    with_meta do
      assert_equal :sent, AdConversions.deliver_meta!(row, settings: @settings, now: @now + 61.minutes)
    end
    assert_equal 2, row.reload.meta_attempts
  end

  test "the nightly sweep cannot deliver an intake event already in flight" do
    lead = ad_lead
    row = AdConversions.record!(lead).first
    calls = 0
    with_meta do |fake|
      fake.define_singleton_method(:request) do |_request|
        calls += 1
        AdConversions::ExportJob.perform_now if calls == 1
        FakeResponse.new("200", { "events_received" => 1 }.to_json)
      end
      AdConversions::LeadJob.perform_now(lead.id)
    end
    assert_equal 1, calls
    assert_equal "sent", row.reload.meta_status
    assert_equal 1, row.meta_attempts
  end

  test "the nightly sweep recovers an interrupted delivery claim" do
    row = AdConversions.record!(ad_lead).first
    row.update!(meta_status: "sending", meta_attempts: 1, updated_at: @now)
    with_meta do |fake|
      AdConversions::ExportJob.perform_now(now: @now + 4.minutes)
      assert_empty fake.requests
      AdConversions::ExportJob.perform_now(now: @now + 6.minutes)
      assert_equal 1, fake.requests.size
    end
    assert_equal "sent", row.reload.meta_status
    assert_equal 2, row.meta_attempts
  end

  test "a late failure cannot overwrite a successful replacement attempt" do
    row = AdConversions.record!(ad_lead).first
    calls = 0
    later = @now + 6.minutes
    with_meta do |fake|
      fake.define_singleton_method(:request) do |_request|
        calls += 1
        if calls == 1
          AdConversions.deliver_meta!(AdConversion.find(row.id), now: later)
          FakeResponse.new("500", { "error" => { "message" => "Late failure" } }.to_json)
        else
          FakeResponse.new("200", { "events_received" => 1 }.to_json)
        end
      end
      assert_nil AdConversions.deliver_meta!(row, now: @now)
    end
    assert_equal 2, calls
    assert_equal "sent", row.reload.meta_status
    assert_equal later, row.meta_sent_at
    assert_nil row.meta_error
    assert_equal 2, row.meta_attempts
  end

  test "a stale excluded row cannot overwrite a completed delivery" do
    lead = ad_lead
    row = AdConversions.record!(lead).first
    stale = AdConversion.find(row.id)
    with_meta { assert_equal :sent, AdConversions.deliver_meta!(row) }
    lead.update!(archived_at: @now)
    assert_nil AdConversions.deliver_meta!(stale)
    assert_equal "sent", row.reload.meta_status
  end

  test "interrupted claims stop retrying at the attempt limit" do
    row = AdConversions.record!(ad_lead).first
    row.update!(meta_status: "sending", meta_attempts: 5, updated_at: @now - 6.minutes)
    with_meta do |fake|
      AdConversions::ExportJob.perform_now(now: @now)
      AdConversions::ExportJob.perform_now(now: @now + 1.day)
      assert_empty fake.requests
    end
    assert_equal "failed", row.reload.meta_status
    assert_equal 5, row.meta_attempts
    assert_match(/attempt limit reached/, row.meta_error)
  end

  test "events past Meta's 7-day limit are skipped, and nothing leaves while Meta is off" do
    lead = ad_lead(received_at: @now - 9.days)
    row = AdConversions.record!(lead, now: @now).first
    assert_equal :skipped, AdConversions.deliver_meta!(row, settings: @settings, now: @now)
    assert_equal "skipped", row.reload.meta_status

    fresh = AdConversions.record!(ad_lead, now: @now).first
    @settings.update!(meta_dataset_id: nil)
    assert_nil AdConversions.deliver_meta!(fresh, settings: @settings, now: @now)
    assert_equal "pending", fresh.reload.meta_status
  end

  test "the Google feed lists click conversions with hashed contact data in Pacific time" do
    lead = ad_lead(fit_band: "strong", status: "quoted", stage_changed_at: Time.utc(2026, 10, 11, 20, 30))
    AdConversions.record!(lead, now: @now)
    rows = AdConversions::GoogleFeed.rows(now: @now)
    assert_equal %w[qualified quote], rows.map(&:event)

    csv = CSV.parse(AdConversions::GoogleFeed.csv(rows))
    assert_equal [ "Parameters:TimeZone=America/Los_Angeles" ], csv[0]
    assert_equal AdConversions::GoogleFeed::HEADERS, csv[1]
    assert_equal [
      "Cj0K-click", Digest::SHA256.hexdigest("annalind@gmail.com"), Digest::SHA256.hexdigest("+14155550134"),
      "Qualified inquiry", "2026-10-11 13:30:00", "1000.00", "USD", "sh-lead-#{lead.id}-qualified"
    ], csv[2]
  end

  test "the Google feed repeats a row for three days after the first pull, within the click window" do
    lead = ad_lead(fit_band: "strong", status: "chatting")
    AdConversions.record!(lead, now: @now)
    AdConversions::GoogleFeed.serve!(settings: @settings, now: @now)
    row = lead.ad_conversions.find_by(event: "qualified")
    assert_equal 1, row.google_serve_count
    assert_equal 1, @settings.reload.google_feed_last_row_count

    assert_equal 1, AdConversions::GoogleFeed.rows(now: @now + 2.days).size
    assert_empty AdConversions::GoogleFeed.rows(now: @now + 4.days)

    old = ad_lead(fit_band: "strong", status: "chatting", received_at: @now - 91.days)
    AdConversions.record!(old, now: @now)
    assert_not AdConversions::GoogleFeed.rows(now: @now).map(&:lead_id).include?(old.id)
  end

  test "rows without a gclid need contact data and the 63-day window" do
    lead = ad_lead(attribution: { "gbraid" => "braid" }, fit_band: "strong", status: "chatting", received_at: @now - 70.days)
    AdConversions.record!(lead, now: @now)
    assert_empty AdConversions::GoogleFeed.rows(now: @now)

    recent = ad_lead(attribution: { "wbraid" => "braid" }, fit_band: "strong", status: "chatting")
    AdConversions.record!(recent, now: @now)
    row = AdConversions::GoogleFeed.rows(now: @now).sole
    assert_nil AdConversions::GoogleFeed.line(row).first
  end

  test "the nightly export records, sends, and writes a one-line result" do
    @settings.update!(meta_dataset_id: "123456789012345")
    @settings.rotate_google_feed_password!
    ad_lead(fit_band: "strong", status: "chatting", created_at: @now - 1.day)
    with_meta do
      AdConversions::ExportJob.perform_now(now: @now)
    end
    @settings.reload
    assert_equal @now, @settings.ad_export_last_run_at
    assert_equal "2 new outcomes recorded. Meta: 2 sent, 0 skipped, 0 failed. Google: 1 in the feed.",
      @settings.ad_export_last_summary
  end

  test "nothing is recorded while both platforms are off" do
    @settings.update!(meta_dataset_id: nil, google_feed_password: nil)
    lead = ad_lead(created_at: @now - 1.day)
    AdConversions::ExportJob.perform_now(now: @now)
    AdConversions::LeadJob.perform_now(lead.id)
    assert_equal 0, AdConversion.count
    assert_nil @settings.reload.ad_export_last_run_at
  end

  test "automation, nudging, and conversion alone do not qualify a lead" do
    lead = ad_lead
    verdict(lead, "strong")
    Leads::Transition.call(lead, to: "chatting", actor: :automation)
    assert_equal %w[lead], AdConversions.record!(lead).map(&:event)
    Leads::Transition.call(lead, to: "nudged")
    assert_empty AdConversions.record!(lead)
    lead.convert_to_client!
    assert_empty AdConversions.record!(lead)
  end

  test "quote history survives a return to chatting before the sweep" do
    lead = ad_lead
    travel_to(@now - 1.day) { Leads::Transition.call(lead, to: "quoted") }
    Leads::Transition.call(lead, to: "chatting")
    row = AdConversions.record!(lead).find { |item| item.event == "quote" }
    assert_equal @now - 1.day, row.occurred_at
  end

  test "qualification uses the later verdict or owner action and respects intervening weak verdicts" do
    lead = ad_lead(received_at: @now - 12.days)
    travel_to(@now - 10.days) { Leads::Transition.call(lead, to: "chatting") }
    verdict(lead, "possible")
    row = AdConversions.record!(lead).find { |item| item.event == "qualified" }
    assert_equal @now, row.occurred_at
    with_meta { assert_equal :sent, AdConversions.deliver_meta!(row) }

    other = ad_lead(received_at: @now - 12.days)
    verdict(other, "strong", at: @now - 10.days)
    verdict(other, "weak", at: @now - 9.days)
    Leads::Transition.call(other, to: "chatting")
    assert_not_includes AdConversions.record!(other).map(&:event), "qualified"
    verdict(other, "possible")
    assert_equal @now, AdConversions.record!(other).sole.occurred_at
  end

  test "business and owner tests are excluded from recording and delivery" do
    old_emails = ENV["ALLOWED_GOOGLE_EMAILS"]
    ENV["ALLOWED_GOOGLE_EMAILS"] = " Captain@example.com , owner@example.com "
    [ "INFO@sherpaholidays.com", Mail.mailbox_address, "CAPTAIN@example.com", "owner@example.com" ].uniq.each do |email|
      lead = ad_lead(email: email)
      assert_empty AdConversions.record!(lead)
    end
    lead = ad_lead(fit_band: "strong", status: "chatting")
    rows = AdConversions.record!(lead)
    lead.update!(email: "captain@example.com")
    with_meta do |fake|
      rows.each { |row| assert_equal :skipped, AdConversions.deliver_meta!(row) }
      assert_empty fake.requests
    end
    assert_empty AdConversions::GoogleFeed.rows
  ensure
    ENV["ALLOWED_GOOGLE_EMAILS"] = old_emails
  end

  test "the intake job sends the Lead event right away" do
    lead = ad_lead(received_at: Time.current)
    with_meta do |fake|
      AdConversions::LeadJob.perform_now(lead.id)
      assert_equal 1, fake.requests.size
    end
    assert_equal "sent", lead.ad_conversions.sole.meta_status
  end
end
