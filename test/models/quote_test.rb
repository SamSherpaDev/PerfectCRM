require "test_helper"

class QuoteTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "needs exactly one owner" do
    bare = Quote.new
    assert_not bare.valid?
    assert_includes bare.errors[:base], "Quote needs exactly one owner: a client or a lead"
    lead = Lead.create!(name: "Pasang", email: "pasang@example.com")
    both = Quote.new(client: @client, lead: lead)
    assert_not both.valid?
    assert_includes both.errors[:base], "Quote needs exactly one owner: a client or a lead"
  end

  test "quote math totals lines and derives the balance" do
    quote = Quote.new(client: @client, deposit_dollars: "100.00")
    quote.lines.build(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
    quote.lines.build(kind: "custom", description: "Permits", quantity: 2, unit_dollars: "50.00")
    quote.save!
    assert_equal 310_000, quote.subtotal_minor
    assert_equal 300_000, quote.balance_due_minor
  end

  test "deposit cannot exceed the total" do
    quote = Quote.new(client: @client, deposit_dollars: "999.00")
    quote.lines.build(kind: "custom", description: "Top-up", quantity: 1, unit_dollars: "10.00")
    assert_not quote.valid?
    assert_includes quote.errors[:deposit_minor], "cannot be more than the quote total"
  end

  test "line total follows quantity times unit" do
    line = QuoteLine.new(quote: Quote.create!(client: @client), kind: "custom",
      description: "Nights", quantity: 3, unit_dollars: "40.00")
    line.valid?
    assert_equal 12_000, line.total_minor
  end

  test "accept token and reference are unique and unguessable" do
    first = Quote.create!(client: @client)
    second = Quote.create!(client: @client)
    assert_not_equal first.accept_token, second.accept_token
    assert_operator first.accept_token.length, :>=, 20
    assert_not_equal first.reference, second.reference
  end

  test "deliver moves a chatting lead to quoted and writes the timeline" do
    lead = Lead.create!(name: "Pasang", email: "pasang@example.com", status: "chatting")
    quote = Quote.create!(lead: lead)
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 1, unit_dollars: "10.00")
    quote.deliver!
    assert_equal "sent", quote.status
    assert_not_nil quote.sent_at
    assert_equal "quoted", lead.reload.status
    assert lead.activity_events.exists?(summary: "Quote #{quote.reference} sent (#{quote.subject_label})")
  end

  test "deliver leaves a nudged lead alone" do
    lead = Lead.create!(name: "Dawa", email: "dawa@example.com", status: "nudged")
    quote = Quote.create!(lead: lead)
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 1, unit_dollars: "10.00")
    quote.deliver!
    assert_equal "nudged", lead.reload.status
  end

  test "expired quotes cannot be accepted" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: 3.days.ago, valid_until: Date.current - 1)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_dollars: "10.00")
    assert quote.expired?
    assert_not quote.accept!
  end

  test "accept stages the intake payload and writes the timeline" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: 1.hour.ago,
      trip_name: "Everest trek", party_size: 2, valid_until: Date.current + 7)
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
    assert quote.accept!
    assert_equal "accepted", quote.status
    payload = JSON.parse(quote.intake_payload)
    assert_equal "Everest trek", payload["trip"]
    assert_equal 2, payload["party_size"]
    assert_equal "maya@example.com", payload["email"]
    assert @client.activity_events.exists?(kind: "quote")
  end

  test "duplicate starts a fresh draft chain with copied lines" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: 1.hour.ago)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_dollars: "10.00")
    copy = quote.duplicate!
    assert_equal "draft", copy.status
    assert_equal 1, copy.version
    assert_nil copy.parent
    assert_not_equal quote.accept_token, copy.accept_token
    assert_equal [ "Trek" ], copy.lines.map(&:description)
  end

  test "revision chains to its parent with a bumped version" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: 1.hour.ago, version: 2)
    revision = quote.new_revision!
    assert_equal quote, revision.parent
    assert_equal 3, revision.version
    assert_equal "draft", revision.status
  end

  test "prefill prefers the same departure and only the sending captain's sent work" do
    sent = Quote.create!(client: @client, status: "accepted", sent_at: 2.days.ago, sent_by_email: "captain@example.com")
    sent.lines.create!(kind: "departure", description: "Everest", quantity: 1,
      unit_minor: 200_000, perfectbook_trip_id: 42, perfectbook_departure_id: 7)
    recent = Quote.create!(client: @client, status: "sent", sent_at: 1.day.ago, sent_by_email: "captain@example.com")
    recent.lines.create!(kind: "trip", description: "Everest", quantity: 1,
      unit_minor: 300_000, perfectbook_trip_id: 42)
    draft = Quote.create!(client: @client, sent_by_email: "captain@example.com")
    draft.lines.create!(kind: "trip", description: "Everest", quantity: 1,
      unit_minor: 1, perfectbook_trip_id: 42)
    other = Quote.create!(client: @client, status: "sent", sent_at: Time.current, sent_by_email: "other@example.com")
    other.lines.create!(kind: "departure", description: "Everest", quantity: 1,
      unit_minor: 2, perfectbook_trip_id: 42, perfectbook_departure_id: 7)
    assert_equal 200_000, Quote.last_unit_for_trip(42, departure_id: 7, sender_email: "captain@example.com")
    assert_equal 300_000, Quote.last_unit_for_trip(42, departure_id: 8, sender_email: "captain@example.com")
    assert_nil Quote.last_unit_for_trip(43, sender_email: "captain@example.com")
    assert_nil Quote.last_unit_for_trip(42, sender_email: nil)
  end

  test "stale accept and view objects cannot repeat or overwrite acceptance" do
    quote = Quote.create!(client: @client, status: "sent")
    stale_accept = Quote.find(quote.id)
    stale_view = Quote.find(quote.id)
    assert_difference -> { @client.activity_events.where(kind: "quote").count }, 1 do
      assert quote.accept!
      assert_not stale_accept.accept!
      stale_view.mark_viewed!
    end
    assert_equal "accepted", quote.reload.status
    assert_equal 0, quote.view_count
  end

  test "duplicate and revision retain a positive deposit and lines" do
    quote = Quote.new(client: @client, status: "sent", deposit_minor: 5000)
    quote.lines.build(kind: "custom", description: "Trek", quantity: 1, unit_minor: 10000)
    quote.save!
    copy = quote.duplicate!
    assert_equal 5000, copy.reload.deposit_minor
    assert_equal 10000, copy.subtotal_minor
    stale = Quote.find(quote.id)
    revision = quote.new_revision!
    assert_equal 5000, revision.reload.deposit_minor
    assert_equal 10000, revision.subtotal_minor
    assert_equal "superseded", quote.reload.status
    assert_not stale.accept!
    assert_equal revision, stale.new_revision!
  end
  test "a stale revision request cannot replace accepted intake" do
    quote = Quote.create!(client: @client, status: "sent", sent_at: Time.current)
    stale = Quote.find(quote.id)
    quote.accept!
    payload = quote.intake_payload
    assert_no_difference "Quote.count" do
      assert_nil stale.new_revision!
    end
    assert_equal "accepted", quote.reload.status
    assert_equal payload, quote.intake_payload
  end

  test "monetary inputs validate the whole value and retain invalid input" do
    quote = Quote.new(client: @client)
    line = quote.lines.build(kind: "custom", description: "Trek", quantity: 1, unit_minor: 200000)
    ["1,500", "12oops", "1e3", "12.345", "-2"].each do |input|
      quote.deposit_dollars = input
      assert_not quote.valid?, "Accepted invalid deposit #{input}"
      assert_equal input, quote.deposit_dollars
      quote.deposit_dollars = "0"
      line.unit_dollars = input
      assert_not quote.valid?, "Accepted invalid price #{input}"
      assert_equal input, line.unit_dollars
      line.unit_dollars = "2000"
    end
    quote.deposit_dollars = " 1500.25 "
    line.unit_dollars = "2000.50"
    quote.save!
    assert_equal 150025, quote.reload.deposit_minor
    assert_equal 200050, quote.lines.first.unit_minor
  end

  test "only untouched new placeholder lines are rejected" do
    quote = Quote.new(client: @client, lines_attributes: {
      "0" => { kind: "custom", description: "", quantity: "1", unit_dollars: "0.00" },
      "1" => { kind: "custom", description: "", quantity: "1", unit_dollars: "1600" },
      "2" => { kind: "custom", description: "", quantity: "2", unit_dollars: "0.00" }
    })
    assert_equal 2, quote.lines.size
    assert_not quote.valid?
    assert quote.lines.all? { |line| line.errors[:description].present? }
  end

  test "delivery reloads line totals before sending a stale draft" do
    quote = Quote.create!(client: @client)
    line = quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    stale = Quote.includes(:lines).find(quote.id)
    line.update!(unit_minor: 160000)
    assert stale.deliver!
    assert_equal 160000, stale.subtotal_minor
    assert_not quote.deliver!
  end

end
