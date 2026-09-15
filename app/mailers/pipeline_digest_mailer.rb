class PipelineDigestMailer < ApplicationMailer
  def weekly(to:, line:)
    @line = line
    mail(to: to, subject: "Pipeline: #{line}")
  end
end
