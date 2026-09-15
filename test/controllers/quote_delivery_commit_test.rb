require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class QuoteDeliveryCommitTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  self.use_transactional_tests = false

  test "edit and send exposes committed terms to the queue worker" do
    sign_in
    user = User.find_by!(google_sub: @claims.fetch("sub"))
    client = Client.create!(name: "Delivery client", email: "delivery@example.com")
    quote = Quote.create!(client: client, party_size: 2, valid_until: Date.current + 14, notes: "Original")
    line = quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_minor: 150000)
    database = SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database)
    observed = nil
    enqueue = ->(job) do
      observed = database.get_first_row(
        "SELECT quotes.notes, quote_lines.unit_minor FROM quotes JOIN quote_lines ON quote_lines.quote_id = quotes.id WHERE quotes.id = ?",
        [ quote.id ]
      )
      job
    end

    QuoteMailer.delivery_job.queue_adapter.stub(:enqueue, enqueue) do
      patch quote_path(quote), params: { send_now: "1", quote: {
        notes: "Updated itinerary",
        lines_attributes: { "0" => { id: line.id, unit_dollars: "1600" } }
      } }
    end

    assert_redirected_to quote_path(quote)
    assert_equal [ "Updated itinerary", 160000 ], observed
    assert_equal "sent", quote.reload.status
  ensure
    database&.close
    quote&.destroy!
    client&.activity_events&.delete_all
    client&.destroy!
    user&.destroy!
  end
end
