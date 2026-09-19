require "test_helper"

class RecordUpcomingTest < ActionView::TestCase
  include ApplicationHelper
  include RecordsHelper

  setup do
    @lead = Lead.create!(name: "Upcoming lead", source: "manual")
    template = Template.create!(name: "Upcoming nudge", subject: "Hello", body: "Checking in")
    @rows = 7.times.map do |i|
      task = @lead.tasks.create!(title: "Follow up #{i}", due_on: Date.current + i, template: template)
      RecordPage::Upcoming.new(task.due_on, :task, task)
    end
  end

  test "read only upcoming hides task actions in both collections" do
    @lead.archive!
    html = Nokogiri::HTML.fragment(render(partial: "records/upcoming",
      locals: { record: @lead, rows: @rows, read_only: true }))

    assert_equal 6, html.css("section > ul.upcoming > li").size
    assert_equal 1, html.css(".upcoming-more li").size
    assert_empty html.css("form, .snooze, .check-btn")
    assert_empty html.css("a").select { |link| link.text == "Nudge" }
    @rows.each { |row| assert_includes html.text, row.record.title }
  end

  test "active upcoming retains task actions in both collections" do
    html = Nokogiri::HTML.fragment(render(partial: "records/upcoming",
      locals: { record: @lead, rows: @rows, read_only: false }))

    assert_equal 7, html.css(".check-btn").size
    assert_equal 7, html.css(".snooze").size
    assert_equal 7, html.css("a").count { |link| link.text == "Nudge" }
    assert_equal 1, html.css(".upcoming-more .check-btn").size
    assert_equal 1, html.css(".upcoming-add").size
  end
end
