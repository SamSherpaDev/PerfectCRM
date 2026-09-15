require "test_helper"

class PipelineDigestJobTest < ActiveJob::TestCase
  test "sends the one-liner to the captain mailbox" do
    Lead.create!(name: "Open ask", source: "manual", expected_value_minor: 500_00)
    before = ActionMailer::Base.deliveries.size
    PipelineDigestJob.perform_now
    assert_equal before + 1, ActionMailer::Base.deliveries.size
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_match(/1 open/, mail.text_part.body.to_s)
  end

  test "stays quiet behind the settings toggle" do
    Setting.current.update!(pipeline_digest: false)
    before = ActionMailer::Base.deliveries.size
    PipelineDigestJob.perform_now
    assert_equal before, ActionMailer::Base.deliveries.size
  end
end
