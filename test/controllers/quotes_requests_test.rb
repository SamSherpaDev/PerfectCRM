require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class QuotesRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com", perfectbook_contact_id: 7)
  end

  test "index tabs carry icons and counts" do
    Quote.create!(client: @client)
    get quotes_path
    assert_response :success
    %w[Draft Sent Accepted Expired].each do |tab|
      assert_select "nav.tabs a", text: /#{tab}/
    end
    assert_select "nav.tabs svg", minimum: 4
  end

  test "client page renders mirrored bookings with money and deep links" do
    PerfectBook::Booking.create!(perfectbook_id: 11, perfectbook_contact_id: 7,
      ref: "BK-11", status: "deposit_received", trip_name: "Everest trek",
      departure_place: "Lukla", start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18),
      party_size: 2, total_minor: 400_000, paid_minor: 100_000, balance_due_minor: 300_000,
      currency: "USD", invoice_badge: "sent", invoice_number: "SH-2027-0142",
      deep_link: "https://perfectbook.example.test/bookings/11", synced_at: Time.current)
    get client_path(@client)
    assert_response :success
    assert_select "h2", text: "Bookings in PerfectBook"
    assert_includes response.body, "BK-11"
    assert_includes response.body, "Everest trek"
    assert_includes response.body, "$4,000.00"
    assert_includes response.body, "$1,000.00"
    assert_includes response.body, "$3,000.00"
    assert_includes response.body, "SH-2027-0142"
    assert_select "a[href='https://perfectbook.example.test/bookings/11']"
    assert_select "form[action=?]", refresh_bookings_client_path(@client)
  end

  test "client page shows the cairn empty state without bookings" do
    get client_path(@client)
    assert_response :success
    assert_includes response.body, "No bookings yet"
    assert_select "use[href='#sk-cairn']"
  end

  test "client page lists quotes with a builder link" do
    quote = Quote.create!(client: @client, trip_name: "Everest trek")
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 1, unit_dollars: "10.00")
    get client_path(@client)
    assert_response :success
    assert_select "h2", text: "Quotes"
    assert_select "a[href=?]", new_quote_path(client_id: @client.id)
    assert_select "a", text: quote.reference
  end

  test "lead page shows booking cards when linked to PerfectBook" do
    lead = Lead.create!(name: "Pasang", email: "pasang@example.com", perfectbook_contact_id: 9)
    PerfectBook::Booking.create!(perfectbook_id: 12, perfectbook_contact_id: 9,
      ref: "BK-12", status: "enquiry", trip_name: "Annapurna", total_minor: 50_000,
      paid_minor: 0, balance_due_minor: 50_000, currency: "USD", synced_at: Time.current)
    get lead_path(lead)
    assert_response :success
    assert_select "h2", text: "Bookings in PerfectBook"
    assert_includes response.body, "BK-12"
  end

  test "lead page hides booking cards without a link" do
    lead = Lead.create!(name: "Dawa", email: "dawa@example.com")
    get lead_path(lead)
    assert_response :success
    assert_select "h2", { text: "Bookings in PerfectBook", count: 0 }
  end

  test "builder creates a draft from catalog and departure" do
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest trek", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      trip_name: "Everest trek", place: "Lukla", start_date: Date.new(2027, 5, 4),
      end_date: Date.new(2027, 5, 18), available_seats: 6, synced_at: Time.current)
    get new_quote_path(client_id: @client.id, trip_id: 42, departure_id: 43)
    assert_response :success
    assert_includes response.body, "6 seats left"

    assert_difference("Quote.count", 1) do
      post quotes_path, params: {
        client_id: @client.id,
        quote: {
          perfectbook_trip_id: 42, perfectbook_departure_id: 43, trip_name: "Everest trek",
          party_size: 2, valid_until: (Date.current + 14).to_s,
          lines_attributes: {
            "0" => { kind: "departure", description: "Everest trek", quantity: "2", unit_dollars: "1500.00" },
            "1" => { kind: "custom", description: "Permits", quantity: "2", unit_dollars: "50.00" },
            "2" => { kind: "custom", description: "", quantity: "1", unit_dollars: "" }
          }
        }
      }
    end
    quote = Quote.order(:created_at).last
    assert_redirected_to quote_path(quote)
    assert_equal "draft", quote.status
    assert_equal 2, quote.lines.count
    assert_equal 310_000, quote.subtotal_minor
    assert_equal "Everest trek", quote.trip_name
    assert_equal Date.new(2027, 5, 4), quote.departure_start_on
  end

  test "send delivers email with PDF and accept link" do
    quote = Quote.create!(client: @client, trip_name: "Everest trek")
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 1, unit_dollars: "10.00")
    assert_enqueued_emails 1 do
      post send_quote_quote_path(quote)
    end
    assert_redirected_to quote_path(quote)
    follow_redirect!
    assert_includes response.body, "Quote sent"
    assert_equal "sent", quote.reload.status
  end

  test "send refuses quotes without lines" do
    quote = Quote.create!(client: @client)
    post send_quote_quote_path(quote)
    assert_redirected_to quote_path(quote)
    assert_equal "draft", quote.reload.status
  end

  test "duplicate and revise keep history" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: 1.hour.ago)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_dollars: "10.00")
    post duplicate_quote_path(quote)
    copy = Quote.order(:created_at).last
    assert_redirected_to quote_path(copy)
    assert_equal "draft", copy.status

    post revise_quote_path(quote)
    revision = Quote.order(:created_at).last
    assert_redirected_to edit_quote_path(revision)
    assert_equal quote, revision.parent
  end

  test "show downloads the PDF" do
    quote = Quote.create!(client: @client, trip_name: "Everest trek")
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 1, unit_dollars: "10.00")
    get quote_path(quote, format: :pdf)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/%PDF/, response.body)
  end

  test "refresh enqueues a single-contact sync" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Maya", synced_at: Time.current)
    assert_enqueued_with(job: PerfectBook::SyncBookingsJob) do
      post refresh_bookings_client_path(@client)
    end
    assert_redirected_to client_path(@client)
  end

  test "quotes require sign-in" do
    delete sign_out_path
    get quotes_path
    assert_redirected_to sign_in_path
  end
  test "removing a line cannot leave the deposit above the saved total" do
    quote = Quote.new(client: @client, deposit_minor: 50_000)
    quote.lines.build(kind: "custom", description: "Small", quantity: 1, unit_minor: 10_000)
    quote.lines.build(kind: "custom", description: "Large", quantity: 1, unit_minor: 90_000)
    quote.save!
    line = quote.lines.find_by!(description: "Large")
    patch quote_path(quote), params: { quote: { lines_attributes: { "0" => { id: line.id, _destroy: "1" } } } }
    assert_response :unprocessable_entity
    assert_includes response.body, "cannot be more than the quote total"
    assert_equal 100_000, quote.reload.subtotal_minor
    assert_equal 2, quote.lines.count
  end

  test "trip only creation snapshots the catalog and remembers inclusions only on request" do
    trip = PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest trek", active: true, synced_at: Time.current)
    get new_quote_path(client_id: @client.id, trip_id: trip.perfectbook_id)
    assert_select "textarea[name='quote[included]']", text: ""
    post quotes_path, params: { client_id: @client.id, remember_inclusions: "1", quote: {
      perfectbook_trip_id: 42, included: "Guide only", lines_attributes: {
        "0" => { kind: "trip", description: "My trek", quantity: 1, unit_dollars: "100" }
      }
    } }
    quote = Quote.order(:id).last
    assert_redirected_to quote_path(quote)
    assert_equal 42, quote.lines.first.perfectbook_trip_id
    assert_equal "Everest trek", quote.lines.first.snapshot_trip_name
    get new_quote_path(client_id: @client.id, trip_id: 42)
    assert_select "textarea[name='quote[included]']", text: "Guide only"
    patch quote_path(quote), params: { quote: { included: "Guide and permits" } }
    assert_equal "Guide only", QuoteTripPreference.find_by!(perfectbook_trip_id: 42).included
    get new_quote_path(client_id: @client.id)
    assert_select "textarea[name='quote[included]']", text: ""
  end

  test "revision edit changes trip and departure snapshots without changing the original" do
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Annapurna", active: true, synced_at: Time.current)
    departure = PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      trip_name: "Annapurna", start_date: Date.new(2027, 6, 1), end_date: Date.new(2027, 6, 10), synced_at: Time.current)
    quote = Quote.create!(client: @client, status: "sent", trip_name: "Everest", perfectbook_trip_id: 7)
    quote.lines.create!(kind: "trip", description: "Everest", quantity: 1, unit_minor: 10000,
      perfectbook_trip_id: 7, snapshot_trip_name: "Everest")
    post revise_quote_path(quote)
    revision = Quote.order(:id).last
    follow_redirect!
    assert_select "select[name='quote[perfectbook_trip_id]']"
    assert_select "select[name='quote[perfectbook_departure_id]']"
    patch quote_path(revision), params: { quote: { perfectbook_trip_id: 42, perfectbook_departure_id: 43 } }
    assert_redirected_to quote_path(revision)
    assert_equal "Annapurna", revision.reload.trip_name
    assert_equal departure.start_date, revision.lines.first.snapshot_start_on
    assert_equal 43, revision.lines.first.perfectbook_departure_id
    assert_equal "Everest", quote.reload.trip_name
    assert_equal "Everest", quote.lines.first.snapshot_trip_name
  end

  test "converted lead quotes appear on the client page" do
    lead = Lead.create!(name: "Pasang", email: "pasang@example.com")
    quote = Quote.create!(lead: lead)
    client = lead.convert_to_client!
    get client_path(client)
    assert_response :success
    assert_select "a[href=?]", quote_path(quote), text: quote.reference
  end

  test "new quote index action opens client selection" do
    get quotes_path
    assert_select "a[href=?]", clients_path, text: "New quote"
    get clients_path
    assert_response :success
    assert_select "a[href=?]", client_path(@client)
  end

  test "document nudge renders the selected booking context without modifying the template" do
    template = Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{full_name}}, {{departure_dates}}: {{missing_documents}}")
    booking = PerfectBook::Booking.create!(perfectbook_id: 99, perfectbook_contact_id: 7,
      ref: "BK-99", trip_name: "Annapurna", start_date: Date.new(2027, 6, 1), end_date: Date.new(2027, 6, 10), synced_at: Time.current)
    get client_path(@client)
    assert_select "a[href=?]", document_nudge_path(booking_id: booking.id)
    assert_includes response.body, "Document status arrives with the PerfectBook update"
    get document_nudge_path(booking_id: booking.id)
    assert_response :success
    assert_select "input[name='recipient'][value=?]", @client.email
    assert_select "textarea[name='body']", text: /Maya Gurung.*Annapurna.*2027.*BK-99/m
    assert_select "textarea[name='body']", text: /Check missing documents in PerfectBook/
    assert_equal "Hi {{full_name}}, {{departure_dates}}: {{missing_documents}}", template.reload.body
  end

  test "revision after acceptance preserves the booking intake panel" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: Time.current)
    quote.accept!
    assert_no_difference "Quote.count" do
      post revise_quote_path(quote)
    end
    assert_redirected_to quote_path(quote)
    follow_redirect!
    assert_includes response.body, "Create booking in PerfectBook"
    assert_equal "accepted", quote.reload.status
  end

  test "failed line edits retain changed added and removed rows for resubmission" do
    quote = Quote.create!(client: @client)
    changed = quote.lines.create!(kind: "custom", description: "Original", quantity: 1, unit_minor: 10000)
    removed = quote.lines.create!(kind: "custom", description: "Remove me", quantity: 1, unit_minor: 90000)
    assert_no_enqueued_emails do
      patch quote_path(quote), params: { send_now: "1", quote: {
        deposit_dollars: "1,500", lines_attributes: {
          "0" => { id: changed.id, description: "Changed", quantity: 2, unit_dollars: "1,500" },
          "1" => { id: removed.id, _destroy: "1" },
          "2" => { kind: "custom", description: "New line", quantity: 1, unit_dollars: "50" }
        }
      } }
    end
    assert_response :unprocessable_entity
    assert_select "input[name='quote[deposit_dollars]'][value='1,500']"
    assert_select "input[name='quote[lines_attributes][0][description]'][value='Changed']"
    assert_select "input[name='quote[lines_attributes][0][quantity]'][value='2']"
    assert_select "input[name='quote[lines_attributes][0][unit_dollars]'][value='1,500']"
    assert_select "[data-line-row].hidden input[data-destroy][value='1']"
    assert_select "input[value='New line']"
    assert_equal "draft", quote.reload.status
    assert_equal 10000, changed.reload.unit_minor
    assert_equal 2, quote.lines.count
  end

  test "a draft loaded before another send cannot update the published quote" do
    quote = Quote.create!(client: @client, notes: "Original")
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    relation = Quote.includes(:lines, :client, :lead)
    load_then_send = ->(id) do
      loaded = Quote.find(id)
      Quote.find(id).deliver!
      loaded
    end
    relation.stub(:find, load_then_send) do
      Quote.stub(:includes, relation) do
        patch quote_path(quote), params: { quote: { notes: "Unsent change" } }
      end
    end
    assert_redirected_to quote_path(quote)
    assert_equal "sent", quote.reload.status
    assert_equal "Original", quote.notes
  end

  test "a stale send request does not enqueue a second email" do
    quote = Quote.create!(client: @client)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    stale = Quote.find(quote.id)
    post send_quote_quote_path(quote)
    relation = Quote.includes(:lines, :client, :lead)
    assert_no_enqueued_emails do
      relation.stub(:find, stale) do
        Quote.stub(:includes, relation) { post send_quote_quote_path(quote) }
      end
    end
    assert_redirected_to quote_path(quote)
    assert_equal 1, @client.activity_events.where(kind: "quote").count
  end

  test "clearing a saved description validates the changed price instead of sending the old price" do
    quote = Quote.create!(client: @client)
    line = quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    assert_no_enqueued_emails do
      patch quote_path(quote), params: { send_now: "1", quote: {
        lines_attributes: { "0" => { id: line.id, description: "", unit_dollars: "1600" } }
      } }
    end
    assert_response :unprocessable_entity
    assert_equal "draft", quote.reload.status
    assert_equal 150000, line.reload.unit_minor
    assert_select "input[name='quote[lines_attributes][0][unit_dollars]'][value='1600.00']"
  end

  test "switching trips ignores the previous trip departure" do
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 44, name: "Annapurna", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      start_date: Date.current + 30, synced_at: Time.current)
    get new_quote_path(client_id: @client.id, trip_id: 44, departure_id: 43)
    assert_response :success
    assert_select "input[name='quote[perfectbook_departure_id]'][value]", count: 0
    assert_select "input[name='quote[trip_name]'][value='Annapurna']"
    assert_select "input[name='quote[lines_attributes][0][description]'][value='Annapurna']"
  end

  test "inactive selected trips survive an unrelated draft edit" do
    trip = PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: false, synced_at: Time.current)
    quote = Quote.create!(client: @client, perfectbook_trip_id: trip.perfectbook_id, trip_name: trip.name)
    quote.lines.create!(kind: "trip", description: "Everest", quantity: 1, unit_minor: 150000,
      perfectbook_trip_id: 42, snapshot_trip_name: "Everest")
    get edit_quote_path(quote)
    assert_select "select[name='quote[perfectbook_trip_id]'] option[selected][value='42']", text: "Everest"
    patch quote_path(quote), params: { quote: { perfectbook_trip_id: "42", perfectbook_departure_id: "", notes: "Updated note" } }
    assert_redirected_to quote_path(quote)
    assert_equal 42, quote.reload.perfectbook_trip_id
    assert_equal "trip", quote.lines.first.kind
    assert_equal "Everest", quote.lines.first.snapshot_trip_name
  end

  test "queue rejection leaves an existing draft retryable with no sent activity" do
    lead = Lead.create!(name: "Pasang", email: "pasang@example.com", status: "chatting")
    quote = Quote.create!(lead: lead)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    reject = ->(_job) { raise ActiveJob::EnqueueError, "Queue unavailable" }
    assert_no_enqueued_emails do
      QuoteMailer.delivery_job.queue_adapter.stub(:enqueue, reject) do
        post send_quote_quote_path(quote)
      end
    end
    assert_redirected_to quote_path(quote)
    assert_equal "draft", quote.reload.status
    assert_nil quote.sent_at
    assert_nil quote.sent_by_email
    assert_equal "chatting", lead.reload.status
    assert_equal 0, lead.activity_events.where(kind: "quote").count
    follow_redirect!
    assert_includes response.body, "Please try sending again"
    assert_enqueued_emails 1 do
      post send_quote_quote_path(quote)
    end
    assert_equal "sent", quote.reload.status
    assert_equal "quoted", lead.reload.status
    assert_equal 1, lead.activity_events.where(kind: "quote").count
  end

  test "queue rejection during edit and send preserves the saved edits as a draft" do
    quote = Quote.create!(client: @client, notes: "Original")
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    reject = ->(_job) { raise SolidQueue::Job::EnqueueError, "Queue database unavailable" }
    QuoteMailer.delivery_job.queue_adapter.stub(:enqueue, reject) do
      patch quote_path(quote), params: { send_now: "1", quote: { notes: "Updated note" } }
    end
    assert_redirected_to quote_path(quote)
    assert_equal "draft", quote.reload.status
    assert_equal "Updated note", quote.notes
    assert_nil quote.sent_at
    assert_equal 0, @client.activity_events.where(kind: "quote").count
    assert_enqueued_emails 1 do
      post send_quote_quote_path(quote)
    end
    assert_equal "sent", quote.reload.status
  end

  test "queue rejection during creation keeps the new draft for retry" do
    reject = ->(_job) { raise ActiveJob::EnqueueError, "Queue unavailable" }
    QuoteMailer.delivery_job.queue_adapter.stub(:enqueue, reject) do
      post quotes_path, params: { client_id: @client.id, send_now: "1", quote: {
        notes: "New journey", lines_attributes: {
          "0" => { kind: "custom", description: "Trek", quantity: "1", unit_dollars: "1500" }
        }
      } }
    end
    quote = Quote.order(:id).last
    assert_redirected_to quote_path(quote)
    assert_equal "draft", quote.status
    assert_equal "New journey", quote.notes
    assert_equal 150000, quote.subtotal_minor
    assert_enqueued_emails 1 do
      post send_quote_quote_path(quote)
    end
    assert_equal "sent", quote.reload.status
  end

end
