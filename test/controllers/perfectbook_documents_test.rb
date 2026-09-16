require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# Booking document status cards, the missing-documents nudge, and the
# Send to PerfectBook hand-off against a stubbed PerfectBook API.
class PerfectBookDocumentsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Ama D", email: "ama@example.com", perfectbook_contact_id: 7)
  end

  def documents_json
    { "travelers" => [
      { "id" => 3, "first_name" => "Ama",
        "documents" => [
          { "type" => "passport", "status" => "received", "received_at" => "2026-08-01" },
          { "type" => "visa", "status" => "missing", "received_at" => nil },
          { "type" => "insurance", "status" => "expiring", "received_at" => "2026-08-02" },
          { "type" => "waiver", "status" => "not_required", "received_at" => nil }
        ] },
      { "id" => 4, "first_name" => "Tashi",
        "documents" => [
          { "type" => "passport", "status" => "missing", "received_at" => nil },
          { "type" => "visa", "status" => "not_required", "received_at" => nil },
          { "type" => "insurance", "status" => "received", "received_at" => "2026-08-03" },
          { "type" => "waiver", "status" => "missing", "received_at" => nil }
        ] }
    ], "missing_count" => 4 }
  end

  def make_booking(documents: documents_json, missing_count: 4, ref: "BK-11")
    PerfectBook::Booking.create!(perfectbook_id: 11, perfectbook_contact_id: 7,
      ref: ref, status: "deposit_received", trip_name: "Everest Base Camp",
      departure_place: "Lukla", start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18),
      party_size: 2, total_minor: 400_000, paid_minor: 100_000, balance_due_minor: 300_000,
      currency: "USD", invoice_badge: "partially_paid", documents_json: documents,
      missing_count: missing_count, checklist_json: [], synced_at: Time.current)
  end

  test "booking card shows each traveler document status with badges and the missing count" do
    make_booking
    get client_path(@client)
    assert_response :success
    assert_includes response.body, "Ama"
    assert_includes response.body, "Tashi"
    %w[Passport Visa Insurance Waiver].each { |type| assert_includes response.body, type }
    assert_includes response.body, "received"
    assert_includes response.body, "missing"
    assert_includes response.body, "expiring"
    assert_includes response.body, "Not required"
    assert_includes response.body, "4 documents missing"
    assert_select "a", text: "Nudge for missing documents", count: 1
  end

  test "booking card hides the nudge when nothing is missing" do
    make_booking(documents: { "travelers" => [
      { "id" => 3, "first_name" => "Ama",
        "documents" => PerfectBook::Booking::DOCUMENT_TYPES.map do |type|
          { "type" => type, "status" => "received", "received_at" => "2026-08-01" }
        end }
    ], "missing_count" => 0 }, missing_count: 0)
    get client_path(@client)
    assert_response :success
    assert_includes response.body, "All documents received."
    assert_select "a", text: "Nudge for missing documents", count: 0
  end

  test "lead booking card shows document status too" do
    lead = Lead.create!(name: "Tashi L", email: "tashi-l@example.com", source: "email", perfectbook_contact_id: 7)
    make_booking
    get lead_path(lead)
    assert_response :success
    assert_includes response.body, "4 documents missing"
    assert_select "a", text: "Nudge for missing documents", count: 1
  end

  test "document nudge names the travelers and exactly the missing types" do
    Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{first_name}}, we still need: {{missing_documents}}")
    booking = make_booking
    get document_nudge_path(booking_id: booking.id)
    assert_response :success
    assert_select "textarea[name='body']", text: /Ama: visa, insurance; Tashi: passport, waiver/m
    assert_select "textarea[name='body']", text: /BK-11/m
    assert_select "textarea[name='body']", text: /2027/m
    assert_select "a", text: "Open in reply box"
  end

  test "nudge link opens the reply box with the document request prefilled" do
    Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{first_name}}, we still need: {{missing_documents}}")
    booking = make_booking
    get client_path(@client, nudge_booking_id: booking.id)
    assert_response :success
    assert_select "textarea.reply-body", text: /we still need: Ama: visa, insurance; Tashi: passport, waiver/m
  end

  test "nudge without an active template fills the missing list and selects the upstream booking" do
    Template.active.for_purpose(:document_request).update_all(archived_at: Time.current)
    booking = make_booking
    booking.update!(perfectbook_id: 811)
    other = booking.dup
    other.assign_attributes(perfectbook_id: 812, ref: "BK-12", trip_name: "Annapurna",
      start_date: booking.start_date + 1.year)
    other.save!

    get client_path(@client, nudge_booking_id: booking.id)
    assert_response :success
    assert_select "textarea.reply-body", text: /Ama: visa, insurance; Tashi: passport, waiver/
    assert_select "select[data-reply-box-target='booking'] option[selected][value='811']"
    context = TemplateContext.for_document_nudge(@client, booking)[:context]
    assert_equal "Ama: visa, insurance; Tashi: passport, waiver", context["missing_documents"]
  end

  test "nudge prefill never clobbers the captain's own draft" do
    Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{first_name}}, we still need: {{missing_documents}}")
    booking = make_booking
    Draft.for_owner(@client, conversation: nil).update!(body: "Captain's own words")
    get client_path(@client, nudge_booking_id: booking.id)
    assert_response :success
    assert_select "textarea.reply-body", text: /Captain's own words/
    assert_no_match(/we still need/, response.body)
  end

  test "today departing-soon rows show the missing count when present" do
    booking = make_booking(ref: "BK-11")
    booking.update!(start_date: Date.current + 5.days, end_date: Date.current + 12.days)
    get root_path
    assert_response :success
    assert_includes response.body, "4 documents missing"
  end

  # -- Send to PerfectBook hand-off --

  def make_holding(filename: "passport.pdf", content_type: "application/pdf", data: "passport-bytes")
    raw = "From: #{@client.email}\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <#{SecureRandom.uuid}@test>\r\nSubject: Docs\r\n\r\nsee attached"
    parsed = Mail::Ingester.parse_raw(raw)
    parsed.attachments = [ { filename: filename, content_type: content_type, data: data } ]
    message = Mail::Ingester.ingest(parsed: parsed, provider: {})[:message]
    holding = DocumentHolding.find_by!(message: message)
    [ message, holding ]
  end

  def stub_pb_upload(result_attrs = {})
    calls = []
    fake = Object.new
    fake.define_singleton_method(:upload_traveler_document) do |**kwargs|
      calls << kwargs
      PerfectBook::Client::UploadResult.new(traveler_id: 3, traveler_name: "Ama",
        document_type: kwargs[:document_type], document_status: "received",
        received_at: "2027-05-01", missing_count: 3,
        duplicate: result_attrs.fetch(:duplicate, false))
    end
    [ fake, calls ]
  end

  test "hand-off uploads through PerfectBook, deletes the CRM copy, and logs the response" do
    booking = make_booking
    message, holding = make_holding
    key = holding.file.blob.key
    fake, calls = stub_pb_upload
    assert_difference([ "ActivityEvent.count", "Note.count" ], 1) do
      PerfectBook::Client.stub(:new, fake) do
        post document_handoffs_path, params: { holding_id: holding.id,
          handoff: { booking_id: booking.id, traveler_id: 3, document_type: "passport" } }
      end
    end
    assert_redirected_to inbox_thread_path(message.conversation)
    follow_redirect!
    assert_match(/Sent passport.pdf to PerfectBook/, flash[:notice].to_s)
    assert_equal "holding-#{holding.id}", calls.first[:upload_id]
    assert_equal "BK-11", calls.first[:booking_ref]
    assert_equal "passport-bytes", calls.first[:file]
    assert_empty DocumentHolding.where(id: holding.id)
    assert_not ActiveStorage::Blob.service.exist?(key)
    assert_empty message.reload.held_attachments
    event = ActivityEvent.order(:id).last
    assert_match(/passport for Ama/, event.summary)
    assert_equal "received", event.metadata["document_status"]
    assert_equal "BK-11", event.metadata["booking_ref"]
    assert_enqueued_jobs 1, only: PerfectBook::SyncBookingsJob
  end

  test "hand-off replay with the same upload id succeeds without duplicating" do
    booking = make_booking
    message, holding = make_holding
    fake, _calls = stub_pb_upload(duplicate: true)
    PerfectBook::Client.stub(:new, fake) do
      post document_handoffs_path, params: { holding_id: holding.id,
        handoff: { booking_id: booking.id, traveler_id: 3, document_type: "passport" } }
    end
    assert_redirected_to inbox_thread_path(message.conversation)
    assert_empty DocumentHolding.where(id: holding.id)
    event = ActivityEvent.order(:id).last
    assert_equal true, event.metadata["duplicate"]
  end

  test "hand-off from a flagged ordinary attachment uploads its stored bytes" do
    booking = make_booking
    conversation = Conversation.create!(subject: "Docs", linkable: @client, last_message_at: Time.current)
    message = conversation.messages.create!(direction: "in", from_address: @client.email,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Docs", sent_at: Time.current, text_body: "see attached")
    message.files.attach(io: StringIO.new("stored-bytes"), filename: "visa.pdf", content_type: "application/pdf")
    attachment = message.files.attachments.first
    fake, calls = stub_pb_upload
    PerfectBook::Client.stub(:new, fake) do
      post document_handoffs_path, params: { attachment_id: attachment.id,
        handoff: { booking_id: booking.id, traveler_id: 3, document_type: "visa" } }
    end
    assert_redirected_to inbox_thread_path(conversation)
    assert_equal "attachment-#{attachment.id}", calls.first[:upload_id]
    assert_equal "stored-bytes", calls.first[:file]
    assert_empty message.reload.files
  end

  test "failed storage deletion preserves an ordinary attachment for hand-off retry" do
    booking = make_booking
    message, _holding = make_holding
    message.files.attach(io: StringIO.new("stored-bytes"), filename: "visa.pdf", content_type: "application/pdf")
    attachment = message.files.attachments.first
    blob = attachment.blob
    fake, calls = stub_pb_upload
    params = { attachment_id: attachment.id,
      handoff: { booking_id: booking.id, traveler_id: 3, document_type: "visa" } }

    PerfectBook::Client.stub(:new, fake) do
      blob.service.stub(:delete, ->(*) { raise IOError, "storage unavailable" }) do
        assert_raises(IOError) { post document_handoffs_path, params: params }
      end
      assert ActiveStorage::Attachment.exists?(attachment.id)
      assert ActiveStorage::Blob.exists?(blob.id)
      assert_equal "stored-bytes", blob.download
      post document_handoffs_path, params: params
    end
    assert_redirected_to inbox_thread_path(message.conversation)
    assert_equal [ "attachment-#{attachment.id}" ] * 2, calls.map { |call| call[:upload_id] }
    assert_not blob.service.exist?(blob.key)
    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  test "failed expiry deletion retains sensitive bytes and references for the next sweep" do
    message, holding = make_holding
    blob = holding.file.blob
    travel 25.hours do
      blob.service.stub(:delete, ->(*) { raise IOError, "storage unavailable" }) do
        assert_raises(IOError) { DocumentHoldingsPurgeJob.perform_now }
      end
      assert DocumentHolding.exists?(holding.id)
      assert ActiveStorage::Blob.exists?(blob.id)
      assert_equal "passport-bytes", holding.reload.file.download
      assert_equal holding.id, message.reload.held_attachments.first["holding_id"]

      DocumentHoldingsPurgeJob.perform_now
    end
    assert_not DocumentHolding.exists?(holding.id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)
    assert_match(/expired/, message.reload.held_attachments.first["status"])
  end

  test "hand-off keeps the CRM copy and shows the error when PerfectBook refuses" do
    booking = make_booking
    message, holding = make_holding
    failing = Object.new
    def failing.upload_traveler_document(**)
      raise PerfectBook::UnprocessableError, "unsupported file type"
    end
    assert_no_difference([ "ActivityEvent.count", "Note.count" ]) do
      PerfectBook::Client.stub(:new, failing) do
        post document_handoffs_path, params: { holding_id: holding.id,
          handoff: { booking_id: booking.id, traveler_id: 3, document_type: "passport" } }
      end
    end
    assert_response :unprocessable_entity
    assert_match(/refused the file/, response.body)
    assert DocumentHolding.exists?(holding.id)
    assert_equal 1, message.reload.held_attachments.size
  end

  test "hand-off form lists the thread's mirrored bookings and travelers" do
    make_booking
    _message, holding = make_holding
    get new_document_handoff_path(holding_id: holding.id)
    assert_response :success
    assert_select "select[name='handoff[booking_id]']"
    assert_select "select[name='handoff[traveler_id]']", text: /Ama/
    assert_select "select[name='handoff[document_type]']", text: /Passport/
  end
end
