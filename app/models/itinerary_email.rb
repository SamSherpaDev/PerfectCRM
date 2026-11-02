# The automatic "Your Nepal itinerary" email: one per itinerary designer
# inquiry, committed with the outbound message it queued. Usage and wording
# approval: README.md, "Leads" (Itinerary designer). It is off until the owner
# switches it on in Settings > Automations after reading the preview.
#
# Transactional, not marketing: mostly the itinerary, a plain subject, the
# link back to the visitor's itinerary and the free-call offer. No prices.
class ItineraryEmail < ApplicationRecord
  SUBJECT = "Your Nepal itinerary".freeze
  # Intake already limits each address to three inquiries an hour; this caps
  # how many itinerary emails one address can receive in a day.
  DAILY_LIMIT = 3
  RESERVED_DOMAINS = %w[example.com example.org example.net example invalid test localhost].freeze

  # The preview's stand-in trip: the designer prototype's "Easy days" draft.
  SAMPLE_ITINERARY = {
    "version" => 1,
    "base_trip" => { "handle" => "pokhara-mountain-views-tour", "title" => "Pokhara Mountain Views Tour" },
    "stops" => [
      { "title" => "Kathmandu", "day_from" => 1, "day_to" => 1 },
      { "title" => "Pokhara and Sarangkot", "day_from" => 2, "day_to" => 3 },
      { "title" => "Dhampus", "day_from" => 4, "day_to" => 4 },
      { "title" => "Ghandruk", "day_from" => 5, "day_to" => 6 },
      { "title" => "Back to Kathmandu and home", "day_from" => 7, "day_to" => 8 }
    ],
    "interests" => [ "Mountain views, easy walking", "Temples and old cities" ],
    "pace" => "easy",
    "length_days" => 7,
    "season" => "fall",
    "group_size" => 2,
    "email_list" => false,
    "share_url" => "https://www.sherpaholidays.com/pages/design-your-trip#p=easy&s=ktm1,sara,dham,ghan,home&n=2&w=fall",
    "source" => "instagram_bio",
    "client_version" => "itinerary-designer@1.0.0"
  }.freeze
  SAMPLE_CALL_REQUEST = { "window" => "weekday_morning", "timezone" => "America/New_York" }.freeze

  belongs_to :lead, optional: true
  belongs_to :message, optional: true

  def self.skip_reason(lead, email:, excluding: nil)
    setting = Setting.current
    return "setting is off" unless setting.itinerary_email_enabled?
    return "old inquiry" if setting.itinerary_email_enabled_at.nil? || lead.created_at <= setting.itinerary_email_enabled_at
    return "no itinerary" unless lead.itinerary
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
      summary: "Itinerary email: #{reason}",
      metadata: { "caller" => "perfectcrm", "message_id" => message&.id })
  end

  # Subject and body for a real inquiry. The call paragraph reflects a call
  # request that arrived before the email was written.
  def self.content_for(lead)
    content(first_name: lead.name.to_s.split.first, itinerary: lead.itinerary, call_request: lead.call_request)
  end

  # Subject and body without the signature: Outbound::Composer appends the
  # Settings signature as it does for every send.
  def self.content(first_name:, itinerary:, call_request: nil)
    labels = Leads::Itinerary
    greeting = labels.safe_text?(first_name, 40) && !first_name.match?(/\d/) ? "Hi #{first_name}," : "Hello,"
    facts = [
      ("Starting from: #{itinerary.dig('base_trip', 'title')}" if itinerary.dig("base_trip", "title").present?),
      ("Length: #{labels.length_label(itinerary['length_days']).upcase_first}" if itinerary["length_days"]),
      ("Pace: #{labels.pace_label(itinerary['pace'])}" if itinerary["pace"]),
      ("When: #{labels.season_label(itinerary['season'])}" if itinerary["season"]),
      ("Travelers: #{itinerary['group_size']}" if itinerary["group_size"]),
      ("Interests: #{itinerary['interests'].join(', ')}" if itinerary["interests"].present?)
    ].compact
    days = itinerary["stops"].map { |stop| "#{labels.day_label(stop)}: #{stop['title']}" }
    paragraphs = [
      greeting,
      "Thank you for designing your trip with SherpaHolidays. Here is the itinerary you built, so you have it to hand.",
      facts.join("\n").presence,
      days.join("\n"),
      ("See or change your itinerary:\n#{itinerary['share_url']}" if itinerary["share_url"].present?),
      call_paragraph(call_request)
    ].compact
    { subject: SUBJECT, body: paragraphs.join("\n\n") }
  end

  def self.call_paragraph(call_request)
    window = Leads::Itinerary.call_window_label(call_request&.dig("window"))
    if window
      "Thank you for asking for a free call. Sam or Gyalgin will email you two call times on #{window.downcase}, your time."
    else
      "Would a free call help? Sam or Gyalgin can go over the route, the season and the pace with you. " \
        "No obligation. Reply to this email with the days and times that usually suit you, and we will send you two call times."
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
    message.mark_failed!("Itinerary email skipped: #{reason}")
    false
  end
end
