# TODO(tasks): append Pipeline::Report#digest_line to the future tasks
# digest instead of sending a separate email. Usage: README.md, "Pipeline".
class PipelineDigestJob < ApplicationJob
  queue_as :default

  CAPTAIN_MAILBOX = "info@sherpaholidays.com"

  def perform
    return unless Setting.current.pipeline_digest

    line = Pipeline::Report.new.digest_line
    PipelineDigestMailer.weekly(to: CAPTAIN_MAILBOX, line: line).deliver_now
  end
end
