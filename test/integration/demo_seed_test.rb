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
end
