require "test_helper"
require_relative "../../db/migrate/20260926205306_refresh_default_template_wording"

class TemplateWordingMigrationTest < ActiveSupport::TestCase
  test "untouched launch templates move to the new wording and edited ones stay" do
    changes = RefreshDefaultTemplateWording::CHANGES
    untouched = changes.map do |name, old_subject, old_body, _new_subject, _new_body|
      Template.create!(name: name, purpose: :custom, subject: old_subject, body: old_body)
    end
    name, old_subject, = changes.first
    untouched.first.update!(body: "My own words")

    ActiveRecord::Migration.suppress_messages { RefreshDefaultTemplateWording.new.migrate(:up) }

    assert_equal [ old_subject, "My own words" ], untouched.first.reload.values_at(:subject, :body)
    untouched.drop(1).zip(changes.drop(1)).each do |template, (_, _, _, new_subject, new_body)|
      assert_equal [ new_subject, new_body ], template.reload.values_at(:subject, :body)
    end
    assert_equal name, untouched.first.name

    ActiveRecord::Migration.suppress_messages { RefreshDefaultTemplateWording.new.migrate(:down) }

    untouched.drop(1).zip(changes.drop(1)).each do |template, (_, old_sub, old_body, _, _)|
      assert_equal [ old_sub, old_body ], template.reload.values_at(:subject, :body)
    end
  end

  test "new wording matches the seeds, with no em dashes and the SherpaHolidays name" do
    load Rails.root.join("db/seeds/templates.rb")
    RefreshDefaultTemplateWording::CHANGES.each do |name, _, _, new_subject, new_body|
      template = Template.find_by!(name: name)
      assert_equal [ new_subject, new_body ], [ template.subject, template.body ]
      assert_no_match(/—/, "#{new_subject}\n#{new_body}")
      assert_no_match(/Sherpa Holidays/, new_body)
    end
  end

  test "the review ask carries the Google link line only once the link is set" do
    _, _, _, subject, body = RefreshDefaultTemplateWording::CHANGES.assoc("Review ask")
    template = Template.create!(name: "Review ask", purpose: :review_ask, subject: subject, body: body)
    context = { first_name: "Maya", trip: "Everest Base Camp trek", my_name: "Sam" }

    without_link = template.rendered(context)
    assert_equal "How was Everest Base Camp trek?", without_link[:subject]
    assert_no_match(/missing|google_review_link|\n\n\n/, without_link[:body])
    assert_includes without_link[:body], "leave a review on Google?"
    assert_includes without_link[:body], "if a friend is thinking about Nepal"

    with_link = template.rendered(context.merge(google_review_link: "https://g.page/r/sherpa/review"))
    assert_includes with_link[:body], "like ours.\n\nhttps://g.page/r/sherpa/review\n\nIf anything"
  end
end
