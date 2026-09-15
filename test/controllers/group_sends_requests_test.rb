require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class GroupSendsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  setup do
    @template = Template.create!(name: "Departure news", purpose: "custom",
      subject: "Hi {{first_name}}", body: "{{full_name}}, see you on {{trip}}!")
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "malformed lines refuse the batch and name their lines" do
    sign_in
    post group_sends_path, params: {
      template_id: @template.id, recipients: "Maya Gurung <maya@example.com>\nnot-an-email\n"
    }
    assert_redirected_to %r{/templates/merge}
    follow_redirect!
    assert_select ".flash-alert", text: /Fix 1 line/
    assert_equal 0, GroupSend.count
    assert_equal 0, Message.count
  end

  test "a clean batch sends one personal email each and opens the summary" do
    sign_in
    assert_difference("GroupSend.count", 1) do
      assert_difference("Message.count", 2) do
        assert_enqueued_jobs 2, only: OutboundDeliveryJob do
          post group_sends_path, params: {
            template_id: @template.id,
            recipients: "Maya Gurung <maya@example.com>\nstranger@example.com\n"
          }
        end
      end
    end
    group = GroupSend.last
    assert_redirected_to group_send_path(group)
    follow_redirect!
    assert_select "h1", "Send summary"
    mine = group.messages.find_by("to_addrs LIKE ?", "%maya@example.com%")
    assert_equal "Hi Maya", mine.subject
    assert_includes mine.text_body, "Maya Gurung"
    assert_equal @client, mine.owner
    other = group.messages.find_by("to_addrs LIKE ?", "%stranger@example.com%")
    assert_nil other.owner
  end

  test "merge preview fills live data and lists broken lines" do
    @client.update!(perfectbook_contact_id: 4242)
    PerfectBook::Booking.create!(perfectbook_id: 9001, perfectbook_contact_id: 4242,
      trip_name: "Everest Base Camp trek", status: "deposit_received",
      balance_due_minor: 185_000, currency: "USD", synced_at: Time.current)
    sign_in
    post merge_templates_path, params: {
      template_id: @template.id,
      recipients: "Maya Gurung <maya@example.com>\nnot-an-email\n"
    }
    assert_response :success
    assert_match(/Everest Base Camp trek/, response.body)
    assert_match(/Line 2/, response.body)
    assert_match(/Not complete/, response.body)
  end

  test "merge takes recipients from a departure's mirrored bookings" do
    departure = PerfectBook::Departure.create!(perfectbook_id: 7001,
      trip_name: "Everest Base Camp trek", label: "May 2027", synced_at: Time.current)
    PerfectBook::Contact.create!(perfectbook_id: 4242, name: "Maya Gurung",
      email: "maya@example.com", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 9002, perfectbook_contact_id: 4242,
      departure_id: 7001, trip_name: "Everest Base Camp trek",
      status: "deposit_received", synced_at: Time.current)
    sign_in
    get merge_templates_path, params: { template_id: @template.id, departure_id: 7001 }
    assert_response :success
    assert_match(/Maya Gurung &lt;maya@example.com&gt;/, response.body)
  end
end
