require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TaskReviewRegressionsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @template = Template.create!(name: "Review", subject: "Hello {{first_name}}",
      body: "Hi {{full_name}}, how was {{trip}}?", purpose: :review_ask)
  end

  test "Today nudges open personalized approval drafts for every subject type" do
    [ Client, Lead, Organization ].each do |model|
      subject = model.create!(name: "Tashi & friends", email: "#{model.name.downcase}@example.com")
      task = subject.tasks.create!(title: "Review #{model.name}", due_on: Date.current, template: @template)
      get root_path
      link = css_select("li").find { |row| row.text.include?(task.title) }.at_css("a.check-link")
      assert_equal polymorphic_path(subject, template: @template.id, task: task.id), link["href"]
      get link["href"]
      assert_response :success
      assert_select "h2", "Suggested message"
      assert_select "textarea", text: "Hi Tashi & friends, how was [missing: trip]?"
      assert_select "button", "Copy message"
      mailto = URI.parse(css_select('a[href^="mailto:"]').last["href"])
      assert_equal subject.email, mailto.opaque.split("?").first
      query = URI.decode_www_form(mailto.opaque.split("?", 2).last).to_h
      assert_equal "Hello Tashi", query["subject"]
      assert_equal "Hi Tashi & friends, how was [missing: trip]?", query["body"]
      assert_not task.reload.done?
    end
  end

  test "suggested messages require a task belonging to the displayed record" do
    client = Client.create!(name: "Tashi")
    other = Client.create!(name: "Other")
    task = other.tasks.create!(title: "Review", due_on: Date.current, template: @template)
    get client_path(client, task: task.id, template: @template.id)
    assert_response :success
    assert_select "#suggested-message-heading", count: 0
  end

  test "automatic proposals wait until forward eligibility" do
    client = Client.create!(name: "Tashi", perfectbook_contact_id: 998)
    booking = PerfectBook::Booking.create!(perfectbook_id: 998, perfectbook_contact_id: 998,
      end_date: Date.new(2026, 1, 31), synced_at: Time.current)
    assert_nil Tasks::Automatic.try_review_ask!(booking, client, Date.new(2026, 2, 2))
    assert_nil Tasks::Automatic.try_repeat_nudge!(booking, client, Date.new(2026, 11, 29))
    assert_difference -> { client.tasks.count }, 1 do
      Tasks::Automatic.try_repeat_nudge!(booking, client, Date.new(2026, 11, 30))
    end
  end

  test "deleting a template preserves open and completed tasks" do
    client = Client.create!(name: "Tashi")
    tasks = [ nil, Time.current ].map do |done_at|
      client.tasks.create!(title: "Review", due_on: Date.current, template: @template, done_at: done_at)
    end
    delete template_path(@template)
    assert_redirected_to templates_path
    tasks.each { |task| assert_nil task.reload.template_id }
  end

  test "conversion transfers tasks and future completion activity to the client" do
    lead = Lead.create!(name: "Tashi")
    task = lead.tasks.create!(title: "Review", due_on: Date.current, template: @template)
    completed = lead.tasks.create!(title: "Earlier", due_on: Date.current, done_at: Time.current)
    post convert_lead_path(lead), params: { expected_client_id: "new" }
    client = lead.reload.converted_client
    assert_equal client, task.reload.subject
    assert_equal client, completed.reload.subject
    patch complete_task_path(task)
    assert client.activity_events.exists?(kind: "task", summary: "Completed: Review")
    assert_not lead.activity_events.exists?(kind: "task", summary: "Completed: Review")
  end

  test "automatic proposals catch late contacts and month end returns once" do
    booking = PerfectBook::Booking.create!(perfectbook_id: 998, perfectbook_contact_id: 998,
      end_date: Date.new(2026, 1, 31), synced_at: Time.current)
    Tasks::Automatic.run!(today: Date.new(2026, 11, 30))
    client = Client.create!(name: "Tashi", perfectbook_contact_id: booking.perfectbook_contact_id)
    Tasks::Automatic.run!(today: Date.new(2026, 12, 1))
    assert_equal 2, client.tasks.count
    assert_equal Date.new(2026, 2, 3), client.tasks.find_by!(kind: "review_ask").due_on
    assert_equal Date.new(2026, 11, 30), client.tasks.find_by!(kind: "follow_up").due_on
    assert_no_difference -> { Task.count } do
      Tasks::Automatic.run!(today: Date.new(2026, 12, 2))
    end
  end
end
