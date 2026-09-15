# Monday 7am one-liner about the pipeline. Runs behind the Settings
# toggle; when the tasks lane lands its own morning digest, append there
# instead (see PipelineDigestJob).
class PipelineDigestMailer < ApplicationMailer
  def weekly(to:, line:)
    @line = line
    mail(to: to, subject: "Pipeline: #{line}")
  end
end
