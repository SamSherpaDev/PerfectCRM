require "test_helper"
require_relative "../../db/seeds/demo_seed"

# The demo seed must load without errors into a fresh database, stay stable
# across reseeds (stages earned after load are never clobbered), and wipe
# back to empty.
class DemoSeedTest < ActiveSupport::TestCase
  DOMAIN = DemoSeed::DEMO_DOMAIN

  test "loads a living dataset, survives a reseed, and wipes cleanly" do
    DemoSeed.load!
    DemoSeed.load!

    assert_equal 6, Client.where("email LIKE ?", "%@#{DOMAIN}").count
    assert_equal 4, Lead.open.where("email LIKE ?", "%@#{DOMAIN}").count
    assert_equal 1, Lead.converted.where("email LIKE ?", "%@#{DOMAIN}").count
    assert_equal 2, Organization.where("email LIKE ?", "%@#{DOMAIN}").count
    assert_operator Message.where(conversation_id: Conversation.where.not(linkable_type: nil).select(:id)).count, :>=, 12
    assert_equal 1, Quote.where(status: "accepted").count
    assert_operator Task.count, :>=, 5
    assert_operator PerfectBook::Departure.count, :>=, 4
    # Hannah earns quoted when her quote is sent; the second load keeps it.
    assert_equal "quoted", Lead.find_by(email: "hannah@#{DOMAIN}").status
    demo_quote_ids = Quote.where(client_id: Client.where("email LIKE ?", "%@#{DOMAIN}").select(:id))
      .or(Quote.where(lead_id: Lead.where("email LIKE ?", "%@#{DOMAIN}").select(:id))).pluck(:id)
    assert_operator demo_quote_ids.size, :>=, 3

    DemoSeed.wipe!
    assert_empty Client.where("email LIKE ?", "%@#{DOMAIN}")
    assert_empty Lead.where("email LIKE ?", "%@#{DOMAIN}")
    assert_empty Organization.where("email LIKE ?", "%@#{DOMAIN}")
    assert_empty Quote.where(id: demo_quote_ids)
    assert_empty PerfectBook::Trip.where("perfectbook_id >= 9000")
  end
  test "wipe preserves unrelated mirrors and demo-domain records" do
    trip = PerfectBook::Trip.create!(perfectbook_id: 99_001, name: "Real trip", synced_at: Time.current)
    client = Client.create!(name: "Real client", email: "real@#{DOMAIN}", kind: "individual")
    DemoSeed.load!
    DemoSeed.wipe!
    assert_equal "Real trip", trip.reload.name
    assert_equal "Real client", client.reload.name
    assert_empty DemoRecord.all
  end

  test "load rejects collisions without changing existing records" do
    [
      [ PerfectBook::Trip, { perfectbook_id: 9001, name: "Real trip" } ],
      [ PerfectBook::Departure, { perfectbook_id: 9101 } ],
      [ PerfectBook::Booking, { perfectbook_id: 18_701, perfectbook_contact_id: 9501 } ],
      [ PerfectBook::Contact, { perfectbook_id: 9501 } ],
      [ Client, { name: "Real client", email: "amara@#{DOMAIN}", kind: "individual" } ],
      [ Organization, { name: "Real operator", email: "namaste@#{DOMAIN}", kind: "operator" } ]
    ].each do |model, attributes|
      attributes[:synced_at] = Time.current if model.column_names.include?("synced_at")
      record = model.create!(attributes)
      original = record.attributes
      error = assert_raises(RuntimeError) { DemoSeed.load! }
      assert_match "Demo seed collision", error.message
      assert_equal original, record.reload.attributes
      assert_empty DemoRecord.all
      record.destroy!
    end
  end

  test "reseed preserves converted leads and their client conversations" do
    DemoSeed.load!
    leads = %w[elena hannah raj james].map { |name| Lead.find_by!(email: "#{name}@#{DOMAIN}") }
    clients = leads.map(&:convert_to_client!)
    originals = leads.map { |lead| lead.reload.attributes }
    counts = [ Client.count, Conversation.count, Message.count, Quote.count, Task.count, Note.count ]

    DemoSeed.load!

    assert_equal originals, leads.map { |lead| lead.reload.attributes }
    assert_equal counts, [ Client.count, Conversation.count, Message.count, Quote.count, Task.count, Note.count ]
    clients.each { |client| assert client.conversations.exists? }
  end

  test "load and wipe leave operational sync cursors untouched" do
    PerfectBook::SyncState.delete_all
    DemoSeed.load!
    assert_empty PerfectBook::SyncState.all
    state = PerfectBook::SyncState.record_success!("contacts", at: 1.year.ago)
    original = state.attributes
    DemoSeed.load!
    DemoSeed.wipe!
    assert_equal original, state.reload.attributes
  end

  test "wipe refuses to delete unmarked records attached to demo owners" do
    DemoSeed.load!
    client = Client.find_by!(email: "amara@#{DOMAIN}")
    note = client.notes.create!(body: "Captain's real note")
    assert_raises(RuntimeError) { DemoSeed.wipe! }
    assert_equal "Captain's real note", note.reload.body
    assert client.reload.persisted?
    assert DemoRecord.exists?
  end
end
