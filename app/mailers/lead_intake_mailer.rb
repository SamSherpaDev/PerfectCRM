# The email copy of every website inquiry, sent to the captain with
# Reply-To the visitor so one tap answers them. Click IDs stay in lead
# metadata and never enter the body.
class LeadIntakeMailer < ApplicationMailer
  def inquiry_copy(lead)
    @lead = lead

    subject = "New inquiry from #{lead.name}: #{lead.trip_title.presence || 'not sure yet'}"
    subject = "[check] #{subject}" if lead.suspected_spam?

    mail(
      to: "info@sherpaholidays.com",
      reply_to: lead.email,
      subject: subject
    )
  end
end
