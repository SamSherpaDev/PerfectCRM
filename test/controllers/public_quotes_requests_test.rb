require "test_helper"
require "minitest/mock"

# The tap-to-accept page is public: the unguessable token is the only key.
class PublicQuotesRequestsTest < ActionDispatch::IntegrationTest
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    @quote = Quote.create!(client: @client, status: "sent", sent_at: 1.hour.ago,
      trip_name: "Everest trek", party_size: 2, valid_until: Date.current + 14,
      included: "Guides, lodges, permits.")
    @quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
  end

  test "client reads the branded quote without signing in" do
    get public_quote_path(@quote.accept_token)
    assert_response :success
    assert_includes response.body, "Your quote is ready"
    assert_includes response.body, "Everest trek"
    assert_includes response.body, "$3,000.00"
    assert_includes response.body, "Guides, lodges, permits."
    assert_select "form[action=?]", accept_public_quote_path(@quote.accept_token)
    assert_select "a[href^='mailto:info@sherpaholidays.com']"
    assert_equal "viewed", @quote.reload.status
  end

  test "unknown tokens 404" do
    get public_quote_path("no-such-token")
    assert_response :not_found
  end

  test "accept records the moment and tells the captain" do
    assert_enqueued_emails 1 do
      post accept_public_quote_path(@quote.accept_token)
    end
    assert_redirected_to public_quote_path(@quote.accept_token)
    follow_redirect!
    assert_includes response.body, "Accepted"
    assert_equal "accepted", @quote.reload.status
    assert_not_nil @quote.accepted_at
    assert @quote.intake_payload.present?
  end

  test "double accept stays accepted without duplicating work" do
    post accept_public_quote_path(@quote.accept_token)
    events = @client.activity_events.where(kind: "quote").count
    post accept_public_quote_path(@quote.accept_token)
    assert_equal "accepted", @quote.reload.status
    assert_equal events, @client.activity_events.where(kind: "quote").count
  end

  test "superseded links stay private until the revision is sent" do
    revision = @quote.new_revision!
    get public_quote_path(@quote.accept_token)
    assert_response :success
    assert_includes response.body, "A newer quote is on its way"
    assert_select "a[href=?]", public_quote_path(revision.accept_token), count: 0
    assert_select "form[action=?]", accept_public_quote_path(@quote.accept_token), count: 0
    assert_no_enqueued_emails do
      post accept_public_quote_path(@quote.accept_token)
      post accept_public_quote_path(revision.accept_token)
      assert_response :not_found
    end
    assert_equal "superseded", @quote.reload.status
    assert_equal "draft", revision.reload.status
    revision.update!(notes: "Private draft notes")
    get public_quote_path(revision.accept_token)
    assert_response :not_found
    assert_equal 0, revision.views.count
    revision.deliver!
    get public_quote_path(@quote.accept_token)
    assert_select "a[href=?]", public_quote_path(revision.accept_token), text: "View the newer quote"
    get public_quote_path(revision.accept_token)
    assert_response :success
    assert_includes response.body, "Private draft notes"
  end

  test "decline endpoint is unavailable" do
    post "/q/#{@quote.accept_token}/decline"
    assert_response :not_found
    assert_equal "sent", @quote.reload.status
  end

  test "expired quotes show expiry and refuse accept" do
    @quote.update!(valid_until: Date.current - 1)
    get public_quote_path(@quote.accept_token)
    assert_response :success
    assert_includes response.body, "expired"
    assert_select "form[action=?]", accept_public_quote_path(@quote.accept_token), count: 0

    post accept_public_quote_path(@quote.accept_token)
    assert_equal "sent", @quote.reload.status
  end

  test "views are rate-limited per address" do
    limit = PublicQuotesController::VIEW_LIMIT
    limit.times { get public_quote_path(@quote.accept_token) }
    assert_response :success
    get public_quote_path(@quote.accept_token)
    assert_response :too_many_requests
  end
  test "every eligible visit increments the count without changing accepted state" do
    3.times { get public_quote_path(@quote.accept_token) }
    assert_equal 3, @quote.reload.view_count
    assert_equal 3, @quote.views.count
    @quote.accept!
    get public_quote_path(@quote.accept_token)
    assert_equal "accepted", @quote.reload.status
    assert_equal 3, @quote.view_count
  end

  %w[ActiveJob::EnqueueError SolidQueue::Job::EnqueueError].each do |error_class|
    test "acceptance remains retryable after #{error_class}" do
      get public_quote_path(@quote.accept_token)
      reject = ->(_job) { raise error_class.constantize, "Queue unavailable" }
      assert_no_enqueued_emails do
        QuoteMailer.delivery_job.queue_adapter.stub(:enqueue, reject) do
          post accept_public_quote_path(@quote.accept_token)
        end
      end
      assert_redirected_to public_quote_path(@quote.accept_token)
      assert_equal "viewed", @quote.reload.status
      assert_nil @quote.accepted_at
      assert_nil @quote.intake_payload
      assert_equal 0, @client.activity_events.where(kind: "quote").count
      follow_redirect!
      assert_includes response.body, "Please try accepting again"
      assert_select "form[action=?]", accept_public_quote_path(@quote.accept_token)
      assert_enqueued_emails 1 do
        post accept_public_quote_path(@quote.accept_token)
      end
      assert_equal "accepted", @quote.reload.status
      assert_not_nil @quote.accepted_at
      assert_equal "Everest trek", JSON.parse(@quote.intake_payload).fetch("trip")
      assert_equal 1, @client.activity_events.where(kind: "quote").count
      assert_no_enqueued_emails do
        post accept_public_quote_path(@quote.accept_token)
      end
    end
  end
end
