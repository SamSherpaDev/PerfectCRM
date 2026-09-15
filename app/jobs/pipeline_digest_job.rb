# Monday 7am pipeline digest. Own mail until the tasks lane lands a
# morning digest to append to; then call this line from there instead.
class PipelineDigestJob < ApplicationJob
  queue_as :default

  CAPTAIN_MAILBOX = "info@sherpaholidays.com"

  def perform
    return unless Setting.current.pipeline_digest

    line = Pipeline::Report.new.digest_line
    PipelineDigestMailer.weekly(to: CAPTAIN_MAILBOX, line: line).deliver_now
  end
end
