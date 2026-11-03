require "uri"

# The structured trip a visitor builds in the website's free itinerary
# designer (placement "itinerary_designer"). Contract: docs/leads-intake.md,
# "Itinerary designer". Only the whitelisted keys below are ever stored:
# no passport, visa, insurance, date-of-birth or payment data, and no prices.
#
# Interests, pace, length and season must be one of the designer's fixed
# choices below. Stop and trip titles are visitor-submitted text: the designer
# takes them from the site's published trips, but the server only filters them
# (text holding links, email addresses, markup or currency is refused) and does
# not check them against the published trips.
module Leads::Itinerary
  VERSION = 1
  INTERESTS = [
    "Everest up close",
    "Temples and old cities",
    "Mountain views, easy walking",
    "Jungle safari in Chitwan",
    "A real Himalayan trek",
    "Birthplace of the Buddha"
  ].freeze
  PACES = {
    "easy" => "Easy days",
    "some_hiking" => "Some hiking",
    "real_trek" => "A real trek"
  }.freeze
  LENGTHS = {
    7 => "about a week",
    14 => "about two weeks",
    21 => "about three weeks"
  }.freeze
  SEASONS = {
    "spring" => "Spring (March to May)",
    "fall" => "Fall (October to December)",
    "winter" => "Winter (January to February)",
    "not_sure" => "Not sure yet"
  }.freeze
  CALL_WINDOWS = {
    "weekday_morning" => "Weekday mornings",
    "weekday_evening" => "Weekday evenings",
    "weekend" => "Weekends"
  }.freeze
  SHARE_HOSTS = %w[www.sherpaholidays.com sherpaholidays.com].freeze
  MAX_STOPS = 30
  MAX_DAYS = 60
  MAX_GROUP_SIZE = 20
  SLUG = /\A[a-z0-9][a-z0-9_-]*\z/
  # Letters (any script), digits, spaces and plain punctuation only: no
  # markup, @, currency symbols, or URL syntax.
  SAFE_TEXT = /\A[\p{L}\p{M}\p{N} .,'’‘“”"()&\/:+!?|#\u2013\u2014-]+\z/
  DOMAIN_LIKE = /[\p{L}\p{N}]\.\p{L}{2,}/
  CURRENCY = /\b(?:usd|eur|gbp|aud|cad|npr|inr)\b/i
  SHARE_PATH = %r{\A/[A-Za-z0-9/_.-]{0,200}\z}
  SHARE_FRAGMENT = /\A[A-Za-z0-9=&,._~%+:-]{0,1000}\z/

  module_function

  # nil when the payload has no itinerary; raises ArgumentError naming the
  # offending field ("itinerary.stops") so intake answers a 400 like the
  # acquisition block does.
  def parse(payload)
    return nil unless payload.key?("itinerary")

    input = payload["itinerary"]
    raise ArgumentError, "itinerary" unless input.is_a?(Hash)

    result = { "version" => VERSION }
    result["base_trip"] = trip_ref(input["base_trip"], "itinerary.base_trip") unless input["base_trip"].nil?
    result["stops"] = stops(input["stops"])
    result["interests"] = interests(input["interests"]) unless input["interests"].nil?
    result["pace"] = choice(input["pace"], PACES, "itinerary.pace") unless input["pace"].nil?
    result["length_days"] = choice(input["length_days"], LENGTHS, "itinerary.length_days") unless input["length_days"].nil?
    result["season"] = choice(input["season"], SEASONS, "itinerary.season") unless input["season"].nil?
    result["group_size"] = integer(input["group_size"], 1..MAX_GROUP_SIZE, "itinerary.group_size") unless input["group_size"].nil?
    unless input["email_list"].nil?
      raise ArgumentError, "itinerary.email_list" unless [ true, false ].include?(input["email_list"])
      result["email_list"] = input["email_list"]
    end
    result["share_url"] = share_url(input["share_url"]) unless input["share_url"].nil?
    result["source"] = slug(input["source"], 40, "itinerary.source") unless input["source"].nil?
    client = payload["client"].is_a?(Hash) ? payload["client"] : {}
    version = client["version"].to_s.strip.first(64).presence
    result["client_version"] = version if version
    result
  end

  # A visitor's free-call request from the details endpoint: a time window and
  # their time zone. Trip quiz leads may leave the window out (call as soon as
  # possible).
  def call_request(input, window_optional: false)
    raise ArgumentError, "call_request" unless input.is_a?(Hash)

    result = {}
    unless window_optional && input["window"].nil?
      result["window"] = choice(input["window"], CALL_WINDOWS, "call_request.window")
    end
    unless input["timezone"].nil?
      zone = input["timezone"]
      valid = zone.is_a?(String) && zone.length <= 64 && zone.match?(%r{\A[A-Za-z]+(?:/[A-Za-z0-9_+-]+){1,2}\z}) &&
        (TZInfo::Timezone.get(zone) rescue nil)
      raise ArgumentError, "call_request.timezone" unless valid
      result["timezone"] = zone
    end
    result
  end

  # Equal for the same trip built twice; used by the 24-hour duplicate merge
  # so a changed itinerary always lands as its own inquiry.
  def signature(itinerary)
    return nil unless itinerary.is_a?(Hash) && itinerary["stops"].is_a?(Array)

    core = {
      "base" => itinerary.dig("base_trip", "handle"),
      "stops" => itinerary["stops"].map { |stop| [ stop["title"].to_s.downcase, stop["day_from"], stop["day_to"] ] },
      "interests" => Array(itinerary["interests"]).map { |value| value.to_s.downcase }.sort,
      "pace" => itinerary["pace"], "length" => itinerary["length_days"],
      "season" => itinerary["season"], "group" => itinerary["group_size"]
    }
    Digest::SHA256.hexdigest(JSON.generate(core))
  end

  def day_label(stop)
    from = stop["day_from"]
    to = stop["day_to"] || from
    to > from ? "Days #{from}-#{to}" : "Day #{from}"
  end

  def planned_days(itinerary)
    Array(itinerary["stops"]).filter_map { |stop| stop["day_to"] || stop["day_from"] }.max
  end

  def length_label(days) = LENGTHS[days]
  def pace_label(value) = PACES[value]
  def season_label(value) = SEASONS[value]
  def call_window_label(value) = CALL_WINDOWS[value]

  # Plain words only: no links, addresses, markup or currency. Also screens
  # the visitor's first name before the automatic email greets them by it.
  def safe_text?(value, max)
    text = value.to_s
    text.length.between?(1, max) && text.match?(SAFE_TEXT) && !text.match?(DOMAIN_LIKE) &&
      !text.match?(CURRENCY) && !text.match?(Leads::URL_PATTERN)
  end

  def source_label(value)
    value.to_s.tr("_-", "  ").squish.capitalize.presence
  end

  def stops(value)
    raise ArgumentError, "itinerary.stops" unless value.is_a?(Array) && value.size.between?(1, MAX_STOPS)

    value.map do |stop|
      raise ArgumentError, "itinerary.stops" unless stop.is_a?(Hash)

      from = integer(stop["day_from"], 1..MAX_DAYS, "itinerary.stops.day_from")
      to = stop["day_to"].nil? ? from : integer(stop["day_to"], from..MAX_DAYS, "itinerary.stops.day_to")
      result = { "title" => text(stop["title"], 120, "itinerary.stops.title"), "day_from" => from, "day_to" => to }
      result["code"] = slug(stop["code"], 40, "itinerary.stops.code") unless stop["code"].nil?
      result["from_trip"] = trip_ref(stop["from_trip"], "itinerary.stops.from_trip") unless stop["from_trip"].nil?
      result
    end
  end
  private_class_method :stops

  def interests(value)
    raise ArgumentError, "itinerary.interests" unless value.is_a?(Array) && value.all? { |interest| INTERESTS.include?(interest) }

    value.uniq
  end
  private_class_method :interests

  def trip_ref(value, field)
    raise ArgumentError, field unless value.is_a?(Hash)

    result = { "handle" => slug(value["handle"], 120, "#{field}.handle") }
    result["title"] = text(value["title"], 160, "#{field}.title") unless value["title"].nil?
    result
  end
  private_class_method :trip_ref

  def text(value, max, field)
    raise ArgumentError, field unless value.is_a?(String)

    # Trip titles may carry en or em dashes; store a plain dash instead.
    cleaned = value.squish.tr("\u2013\u2014", "--")
    raise ArgumentError, field unless safe_text?(cleaned, max)

    cleaned
  end
  private_class_method :text

  def slug(value, max, field)
    raise ArgumentError, field unless value.is_a?(String) && value.length <= max && value.match?(SLUG)

    value
  end
  private_class_method :slug

  def integer(value, range, field)
    raise ArgumentError, field unless value.is_a?(Integer) && range.cover?(value)

    value
  end
  private_class_method :integer

  def choice(value, choices, field)
    raise ArgumentError, field unless choices.key?(value)

    value
  end
  private_class_method :choice

  # Our own page only, over https, without credentials, port or query (a
  # query could carry click ids); the fragment holds the visitor's choices.
  def share_url(value)
    field = "itinerary.share_url"
    raise ArgumentError, field unless value.is_a?(String) && value.length <= 1200

    uri = URI.parse(value.strip)
    raise ArgumentError, field unless uri.scheme == "https" && SHARE_HOSTS.include?(uri.host.to_s.downcase) &&
      uri.userinfo.nil? && [ nil, 443 ].include?(uri.port) && uri.path.to_s.match?(SHARE_PATH) &&
      uri.fragment.to_s.match?(SHARE_FRAGMENT)

    "https://#{uri.host.downcase}#{uri.path.presence || '/'}#{"##{uri.fragment}" if uri.fragment.present?}"
  rescue URI::InvalidURIError
    raise ArgumentError, field
  end
  private_class_method :share_url
end
