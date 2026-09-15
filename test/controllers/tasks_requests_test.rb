require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TasksRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 11)
  end

  test "create from the client card saves a follow-up" do
    assert_difference -> { @client.tasks.count }, 1 do
      post tasks_path(subject_type: "Client", subject_id: @client.id),
        params: { task: { title: "Nudge Maya", due_on: Date.current.to_s } }
    end
    assert_redirected_to @client
    follow_redirect!
    assert_select "li", text: /Nudge Maya/
  end

  test "create rejects unknown subject types" do
    assert_no_difference -> { Task.count } do
      post tasks_path(subject_type: "Booking", subject_id: 1),
        params: { task: { title: "X", due_on: Date.current.to_s } }
    end
    assert_response :not_found
  end

  test "complete stamps done and writes the timeline event" do
    task = @client.tasks.create!(title: "Nudge", due_on: Date.current)
    assert_difference -> { @client.activity_events.count }, 1 do
      patch complete_task_path(task)
    end
    assert task.reload.done?
    assert_redirected_to root_path
  end

  test "snooze takes presets and a picked date" do
    task = @client.tasks.create!(title: "Nudge", due_on: Date.current)
    patch snooze_task_path(task, preset: "tomorrow")
    assert_equal Date.current + 1, task.reload.snoozed_until

    patch snooze_task_path(task), params: { snoozed_until: (Date.current + 9).to_s }
    assert_equal Date.current + 9, task.reload.snoozed_until
  end

  test "snooze without a date asks for one" do
    task = @client.tasks.create!(title: "Nudge", due_on: Date.current)
    patch snooze_task_path(task)
    assert_redirected_to root_path
    follow_redirect!
    assert_select "p", text: /Pick a date/
    assert_nil task.reload.snoozed_until
  end

  test "create review ask from a returned booking" do
    booking = PerfectBook::Booking.create!(perfectbook_id: 210, perfectbook_contact_id: 11,
      trip_name: "Everest", end_date: Date.current - 2, synced_at: Time.current)
    assert_difference -> { @client.tasks.count }, 1 do
      post create_review_ask_tasks_path, params: { booking_id: booking.id }
    end
    assert_equal "review_ask", @client.tasks.last.kind
  end

  test "client page renders the suggested nudge template" do
    template = Template.create!(name: "Deposit nudge", body: "Hi", purpose: "deposit_nudge")
    task = @client.tasks.create!(title: "Nudge", due_on: Date.current, template: template)
    get client_path(@client, template: template.id, task: task.id)
    assert_response :success
    assert_select "h2", "Suggested message"
    assert_select "textarea", text: "Hi"
  end
end
