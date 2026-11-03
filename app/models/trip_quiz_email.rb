# The automatic "Your trip match" email: one per trip quiz inquiry, committed
# with the outbound message it queued. Usage and wording approval: README.md,
# "Leads" (Trip quiz). It is off until the owner switches it on in Settings >
# Automations after reading the preview.
#
# Transactional, not marketing: the matched trip with its link, one short line
# per answer on why it fits, the closest alternate trips with links, and the
# free-call offer or confirmation. No prices.
class TripQuizEmail < ApplicationRecord
  SUBJECT = "Your trip match".freeze
  DAILY_LIMIT = 3
  RESERVED_DOMAINS = %w[example.com example.org example.net example invalid test localhost].freeze

  SAMPLE_QUIZ = {
    "version" => 1,
    "match" => {
      "handle" => "nepal-cultural-wildlife-tour",
      "title" => "15-Day Nepal Cultural and Wildlife Tour"
    },
    "alternates" => [
      {
        "handle" => "nepal-luxury-tour-kathmandu-chitwan-pokhara",
        "title" => "13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara"
      },
      {
        "handle" => "nepal-highlights-premium-tour",
        "title" => "9-Day Nepal Highlights Premium Tour"
      }
    ],
    "interests" => [ "temples", "jungle-safari", "lumbini" ],
    "pace" => "easy",
    "length" => "under-14",
    "season" => "spring",
    "group_size" => 4,
    "intent" => "email",
    "email_list" => false,
    "share_url" => "https://www.sherpaholidays.com/pages/find-your-perfect-trip#k=temples,jungle-safari,lumbini&p=easy&l=under-14&s=spring&n=4",
    "source" => "website",
    "client_version" => "trip-quiz-1"
  }.freeze
  SAMPLE_CALL_REQUEST = { "timezone" => "America/New_York" }.freeze

  belongs_to :lead, optional: true
  belongs_to :message, optional: true

  def self.skip_reason(lead, email:, excluding: nil)
    setting = Setting.current
    return "setting is off" unless setting.trip_quiz_email_enabled?
    return "old inquiry" if setting.trip_quiz_email_enabled_at.nil? || lead.created_at <= setting.trip_quiz_email_enabled_at
    return "no quiz" unless lead.quiz
    return "not a website inquiry" unless lead.capture_channel == "website_form" && lead.external_ref.to_s.start_with?("website_form:")
    return "invalid email" unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
    return "address changed" unless lead.effective_recipient_email(email) == email && lead.email.to_s.strip.downcase == email

    domain = email.split("@").last
    return "our own domain" if domain == "sherpaholidays.com" || domain.end_with?(".sherpaholidays.com")
    return "test address" if lead.is_test? || RESERVED_DOMAINS.any? { |name| domain == name || domain.end_with?(".#{name}") }
    return "spam or junk" if lead.spam_score.positive? || lead.suspected_spam?
    return "not interested" if lead.not_interested?
    return "inactive inquiry" if lead.archived? || lead.converted? || lead.status == "lost"
    return "daily limit for this address" if
      where(email: email).where.not(id: excluding).where("created_at > ?", 24.hours.ago).count >= DAILY_LIMIT

    nil
  end

  def self.log(lead, reason, message: nil)
    lead.activity_events.create!(kind: "automation", occurred_at: Time.current,
      summary: "Trip quiz email: #{reason}",
      metadata: { "caller" => "perfectcrm", "message_id" => message&.id })
  end

  # Subject and body for a real inquiry. The call paragraph reflects a call
  # request that arrived before the email was written.
  def self.content_for(lead)
    content(first_name: lead.name.to_s.split.first, quiz: lead.quiz, call_request: lead.call_request)
  end

  # Subject and body without the signature: Outbound::Composer appends the
  # Settings signature as it does for every send.
  def self.content(first_name:, quiz:, call_request: nil)
    greeting = Leads::Itinerary.safe_text?(first_name, 40) && !first_name.to_s.match?(/\d/) ? "Hi #{first_name}," : "Hello,"
    match = quiz["match"].is_a?(Hash) ? quiz["match"] : {}
    match_title = match["title"].presence || match["handle"]
    match_url = Leads::TripQuiz.trip_url(match["handle"])
    match_block = [
      ("Your match: #{match_title}" if match_title.present?),
      match_url
    ].compact.join("\n").presence

    why_lines = Leads::TripQuiz.why_it_fits(quiz)
    why_block = if why_lines.any?
      ([ "Why it fits:" ] + why_lines.map { |line| "- #{line}" }).join("\n")
    end

    alternates = Array(quiz["alternates"]).select { |alt| alt.is_a?(Hash) && (alt["title"].present? || alt["handle"].present?) }
    alternates_block = if alternates.any?
      alt_lines = alternates.map do |alt|
        title = alt["title"].presence || alt["handle"]
        url = Leads::TripQuiz.trip_url(alt["handle"])
        url ? "- #{title}\n  #{url}" : "- #{title}"
      end
      ([ "Also close:" ] + alt_lines).join("\n")
    end

    paragraphs = [
      greeting,
      "Thank you for taking our trip quiz at SherpaHolidays. Here is your best match from our trips, so you have it to hand.",
      match_block,
      why_block,
      alternates_block,
      call_paragraph(call_request, intent: quiz["intent"])
    ].compact
    { subject: SUBJECT, body: paragraphs.join("\n\n") }
  end

  def self.call_paragraph(call_request, intent: nil)
    if intent == "call" || call_request.present?
      "Thank you for asking for a free call. Sam or Gyalgin will call you as soon as possible."
    else
      "Would a free call help? Sam or Gyalgin can go over this trip, the season and the pace with you. " \
        "No obligation. Reply to this email with your phone number and we will call you as soon as possible."
    end
  end
  private_class_method :call_paragraph

  def claim_delivery!
    self.class.where(id: id, delivery_attempted_at: nil).update_all(delivery_attempted_at: Time.current) == 1
  end

  # The switch and a late spam verdict apply even if delivery was delayed.
  def delivery_allowed?
    reason = lead ? self.class.skip_reason(lead.reload, email: email, excluding: id) : "inquiry removed"
    return true unless reason

    self.class.log(lead, "skipped (#{reason})", message: message) if lead
    message.mark_failed!("Trip quiz email skipped: #{reason}")
    false
  end
end
