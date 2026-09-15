require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TodayRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 11)
  end

  test "today renders the four tiles with sentence-case labels" do
    get root_path
    assert_response :success
    assert_select "h1", "Today"
    assert_select ".stat", count: 4
    assert_select ".stat", text: /Waiting on you/
    assert_select ".stat", text: /Follow-ups due/
    assert_select ".stat", text: /Quotes out/
    assert_select ".stat", text: /Overdue/
  end

  test "today lists follow-ups with one-tap complete and nudge" do
    template = Template.create!(name: "Deposit nudge", body: "Hi", purpose: "deposit_nudge")
    task = @client.tasks.create!(title: "Nudge Maya", due_on: Date.current, template: template)
    other = @client.tasks.create!(title: "Snoozed away", due_on: Date.current - 2)
    other.snooze!("week")

    get root_path
    assert_response :success
    assert_select "h2", text: "Follow-ups"
    assert_select "li", text: /Nudge Maya/
    assert_select "form[action=?]", complete_task_path(task)
    assert_select "a[href=?]", client_path(@client, template: template.id), text: "Nudge"
    assert_select "li", text: /Snoozed away/, count: 0
  end

  test "today shows departing soon and back from the mountains" do
    PerfectBook::Booking.create!(perfectbook_id: 200, perfectbook_contact_id: 11,
      trip_name: "Everest", start_date: Date.current + 5, party_size: 2, synced_at: Time.current)
    home = PerfectBook::Booking.create!(perfectbook_id: 201, perfectbook_contact_id: 11,
      trip_name: "Annapurna", end_date: Date.current - 2, synced_at: Time.current)

    get root_path
    assert_response :success
    assert_select "h2", text: "Departing soon"
    assert_select "li", text: /Everest/
    assert_select "h2", text: "Back from the mountains"
    assert_select "li", text: /Annapurna/
    assert_select "form[action=?]", create_review_ask_tasks_path
    assert_select "form input[name=booking_id][value='#{home.id}']"
  end

  test "today with nothing to do shows the empty states" do
    get root_path
    assert_response :success
    assert_select "p", text: /Nothing owed this week/
    assert_select "p", text: /No replies waiting/
  end
end
