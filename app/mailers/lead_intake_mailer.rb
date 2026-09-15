# The email copy of every website inquiry, sent to the captain with
# Reply-To the visitor so one tap answers them. Click IDs stay in lead
# metadata and never enter the body.
class LeadIntakeMailer < ApplicationMailer
  def inquiry_copy(lead)
    @lead = lead
    settings = Setting.current
    copy_to = settings.intake_copy_to.presence || Setting::DEFAULT_INTAKE_COPY_TO

    subject = "New inquiry from #{lead.name}: #{lead.trip_title.presence || 'not sure yet'}"
    subject = "[check] #{subject}" if lead.suspected_spam?

    mail(
      to: copy_to,
      reply_to: lead.email,
      from: copy_to,
      subject: subject
    )
  end
end
