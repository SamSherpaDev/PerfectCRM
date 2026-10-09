class ReplyAlertMailer < ApplicationMailer
  def reply_received(message)
    owner = Mail::Matcher.call([ message.from_address ]).linkable
    sender = Person.find_by(email: message.from_address) || owner
    name = sender&.name.presence || message.from_address
    trip = TemplateContext.for_reply(to: message.from_address, owner: owner)[:context]["trip"] if owner.is_a?(Lead) || owner.is_a?(Client)
    headers["Auto-Submitted"] = "auto-generated"
    headers["X-Auto-Response-Suppress"] = "All"
    mail(from: Outbound::Composer.from_display, to: "info@sherpaholidays.com",
      subject: "Reply from #{name}: #{trip.presence || 'Nepal trip'}") do |format|
      format.text do
        render plain: "#{name} <#{message.from_address}>\nReceived: #{(message.inbound_received_at || message.sent_at).iso8601}\n\n#{message.preview_text(300)}\n\nRespond in PerfectCRM:\n#{inbox_thread_url(message.conversation)}\n"
      end
    end
  end
end
