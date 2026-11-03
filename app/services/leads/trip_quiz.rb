require "uri"

# The structured answers and matched trips from the website's "Find your
# perfect trip" questionnaire (placement "trip_quiz"). Contract:
# docs/leads-intake.md, "Trip quiz". Only the whitelisted keys below are
# ever stored: no passport, visa, insurance, date-of-birth or payment data,
# and no prices.
module Leads::TripQuiz
  INTERESTS = {
    "everest" => "Everest up close",
    "temples" => "Temples and old cities",
    "mountain-views" => "Mountain views, easy walking",
    "jungle-safari" => "Jungle safari in Chitwan",
    "himalayan-trek" => "A real Himalayan trek",
    "lumbini" => "Birthplace of the Buddha",
    "peak" => "Climb a Himalayan peak",
    "rafting" => "White-water rafting",
    "beyond" => "Tibet, Bhutan or India",
    "remote" => "Remote, restricted regions"
  }.freeze
  PACES = {
    "easy" => "Easy days",
    "moderate" => "Some hiking",
    "challenging" => "A real trek",
    "strenuous" => "A big challenge"
  }.freeze
  PACE_RANKS = {
    "easy" => 0,
    "moderate" => 1,
    "challenging" => 2,
    "strenuous" => 3
  }.freeze
  LEVEL_RANKS = {
    "Easy" => 0,
    "Moderate" => 1,
    "Challenging" => 2,
    "Strenuous" => 3
  }.freeze
  LENGTHS = {
    "under-14" => "Under two weeks",
    "14-20" => "Two to three weeks",
    "21-plus" => "Three weeks or more",
    "not_sure" => "Not sure yet"
  }.freeze
  SEASONS = {
    "spring" => "Spring (March to May)",
    "summer" => "Summer (June to September)",
    "fall" => "Autumn (October to December)",
    "winter" => "Winter (January to February)",
    "not_sure" => "Not sure yet"
  }.freeze
  LENGTH_DAYS = {
    "under-14" => 1..13,
    "14-20" => 14..20,
    "21-plus" => 21..
  }.freeze
  SEASON_SHORT_LABELS = {
    "spring" => "Spring",
    "summer" => "Summer",
    "fall" => "Autumn",
    "winter" => "Winter",
    "not_sure" => "Not sure yet"
  }.freeze
  TRIP_SEASONS = {
    "Spring & Autumn" => %w[spring fall],
    "Autumn to Spring" => %w[fall winter spring],
    "Spring to Autumn" => %w[spring summer fall]
  }.freeze
  INTENTS = {
    "email" => "Email their match",
    "call" => "Free call"
  }.freeze
  # Confirmed facts for the 35 published trips in the store's find-your-trip
  # collection (experience level, day count, best season and product tags).
  TRIPS = {
    "everest-base-camp-premium-trek" => { level: "Challenging", days: 18, season: "Spring & Autumn", tags: [ "Everest Region", "Trekking" ] },
    "everest-base-camp-gokyo-trek" => { level: "Challenging", days: 20, season: "Spring & Autumn", tags: [ "Everest Region", "Trekking" ] },
    "nepal-highlights-premium-tour" => { level: "Easy", days: 9, season: "Spring & Autumn", tags: [ "Chitwan", "Cultural Tour", "Kathmandu Valley", "Pokhara", "Wildlife Safari" ] },
    "nepal-luxury-tour-kathmandu-chitwan-pokhara" => { level: "Easy", days: 13, season: "Spring & Autumn", tags: [ "Chitwan", "Cultural Tour", "Kathmandu Valley", "Pokhara", "Wildlife Safari" ] },
    "nepal-bhutan-premium-tour" => { level: "Moderate", days: 14, season: "Spring & Autumn", tags: [ "Bhutan", "Chitwan", "Cultural Tour", "Kathmandu Valley" ] },
    "india-nepal-premium-tour" => { level: "Easy", days: 13, season: "Autumn to Spring", tags: [ "Cultural Tour", "India", "Kathmandu Valley" ] },
    "buddhist-pilgrimage-tour-india-nepal" => { level: "Easy", days: 14, season: "Autumn to Spring", tags: [ "Cultural Tour", "India", "Lumbini" ] },
    "nepal-cultural-wildlife-tour" => { level: "Easy", days: 15, season: "Spring & Autumn", tags: [ "Chitwan", "Cultural Tour", "Kathmandu Valley", "Lumbini", "Pokhara", "Wildlife Safari" ] },
    "annapurna-circuit-trek-nepal" => { level: "Challenging", days: 23, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "langtang-valley-trek-nepal" => { level: "Moderate", days: 13, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "mustang-poon-hill-trek-nepal" => { level: "Moderate", days: 15, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "annapurna-base-camp-trek-nepal" => { level: "Moderate", days: 16, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "upper-mustang-trek-lo-manthang" => { level: "Moderate", days: 21, season: "Spring & Autumn", tags: [ "Restricted Region", "Trekking" ] },
    "annapurna-everest-combined-trek-nepal" => { level: "Moderate", days: 21, season: "Spring & Autumn", tags: [ "Everest Region", "Trekking" ] },
    "manaslu-circuit-trek-nepal" => { level: "Challenging", days: 22, season: "Spring & Autumn", tags: [ "Restricted Region", "Trekking" ] },
    "nepal-trek-safari-lakes-tour" => { level: "Moderate", days: 14, season: "Spring & Autumn", tags: [ "Chitwan", "Everest Region", "Pokhara", "Trekking", "Wildlife Safari" ] },
    "royal-trek-chitwan-pokhara-nepal" => { level: "Easy", days: 12, season: "Autumn to Spring", tags: [ "Chitwan", "Cultural Tour", "Pokhara", "Trekking", "Wildlife Safari" ] },
    "island-peak-climbing-nepal" => { level: "Strenuous", days: 17, season: "Spring & Autumn", tags: [ "Everest Region", "Peak Climbing" ] },
    "lobuche-peak-climbing-expedition-nepal" => { level: "Strenuous", days: 19, season: "Spring & Autumn", tags: [ "Everest Region", "Peak Climbing" ] },
    "mera-peak-climbing-nepal" => { level: "Strenuous", days: 20, season: "Spring & Autumn", tags: [ "Everest Region", "Peak Climbing" ] },
    "pachermo-peak-climbing-nepal" => { level: "Strenuous", days: 24, season: "Spring & Autumn", tags: [ "Everest Region", "Peak Climbing" ] },
    "kanchenjunga-base-camp-trek-nepal" => { level: "Strenuous", days: 21, season: "Spring & Autumn", tags: [ "Restricted Region", "Trekking" ] },
    "makalu-base-camp-trek-nepal" => { level: "Strenuous", days: 22, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "rolwaling-valley-trek-nepal" => { level: "Strenuous", days: 22, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "great-himalayan-chain-trek-nepal" => { level: "Moderate", days: 21, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "rara-lake-trek-far-west-nepal" => { level: "Moderate", days: 16, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "dhaulagiri-circuit-trek-nepal" => { level: "Strenuous", days: 23, season: "Spring & Autumn", tags: [ "Trekking" ] },
    "upper-dolpo-trek-nepal" => { level: "Strenuous", days: 29, season: "Spring & Autumn", tags: [ "Restricted Region", "Trekking" ] },
    "trishuli-river-rafting-tour-nepal" => { level: "Easy", days: 5, season: "Spring & Autumn", tags: [ "Kathmandu Valley", "Rafting" ] },
    "kali-gandaki-rafting-tour-nepal" => { level: "Moderate", days: 10, season: "Spring & Autumn", tags: [ "Rafting" ] },
    "arun-river-rafting-expedition-nepal" => { level: "Moderate", days: 9, season: "Spring & Autumn", tags: [ "Rafting" ] },
    "tibet-overland-tour-lhasa" => { level: "Moderate", days: 8, season: "Spring to Autumn", tags: [ "Cultural Tour", "Tibet" ] },
    "nepal-tibet-kailash-kora-tour" => { level: "Strenuous", days: 17, season: "Spring to Autumn", tags: [ "Cultural Tour", "Kathmandu Valley", "Pokhara", "Tibet" ] },
    "solu-mountain-views-tour" => { level: "Easy", days: 9, season: "Spring & Autumn", tags: [] },
    "pokhara-mountain-views-tour" => { level: "Easy", days: 8, season: "Spring & Autumn", tags: [] }
  }.transform_values(&:freeze).freeze

  SHARE_HOSTS = %w[www.sherpaholidays.com sherpaholidays.com].freeze
  MAX_GROUP_SIZE = 20
  MAX_ALTERNATES = 2
  HANDLE = /\A[a-z0-9][a-z0-9-]{0,99}\z/
  SOURCE = /\A[a-z0-9][a-z0-9_-]{0,39}\z/
  SHARE_PATH = %r{\A/[A-Za-z0-9/_.-]{0,200}\z}
  SHARE_FRAGMENT = /\A[A-Za-z0-9=&,._~%+:-]{0,1000}\z/

  module_function

  # nil when the payload has no quiz; raises ArgumentError naming the
  # offending field ("quiz.pace") so intake answers a 400.
  def parse(payload)
    return nil unless payload.is_a?(Hash) && payload.key?("quiz")

    input = payload["quiz"]
    raise ArgumentError, "quiz" unless input.is_a?(Hash)

    result = {}
    result["match"] = trip_ref(input["match"], "quiz.match")
    result["alternates"] = alternates(input["alternates"]) unless input["alternates"].nil?
    result["interests"] = interests(input["interests"]) unless input["interests"].nil?
    result["pace"] = choice(input["pace"], PACES, "quiz.pace") unless input["pace"].nil?
    result["length"] = choice(input["length"], LENGTHS, "quiz.length") unless input["length"].nil?
    result["season"] = choice(input["season"], SEASONS, "quiz.season") unless input["season"].nil?
    result["group_size"] = integer(input["group_size"], 1..MAX_GROUP_SIZE, "quiz.group_size") unless input["group_size"].nil?
    result["intent"] = choice(input["intent"], INTENTS, "quiz.intent") unless input["intent"].nil?
    unless input["email_list"].nil?
      raise ArgumentError, "quiz.email_list" unless [ true, false ].include?(input["email_list"])
      result["email_list"] = input["email_list"]
    end
    result["share_url"] = share_url(input["share_url"]) unless input["share_url"].nil?
    result["source"] = source(input["source"]) unless input["source"].nil?
    result
  end

  # Equal for the same match and answers sent twice; used by the 24-hour
  # duplicate merge so changed answers land as their own inquiry.
  def signature(quiz)
    return nil unless quiz.is_a?(Hash) && quiz["match"].is_a?(Hash)

    core = {
      "match" => quiz.dig("match", "handle"),
      "interests" => Array(quiz["interests"]).map { |value| value.to_s.downcase }.sort,
      "pace" => quiz["pace"],
      "length" => quiz["length"],
      "season" => quiz["season"],
      "group" => quiz["group_size"]
    }
    Digest::SHA256.hexdigest(JSON.generate(core))
  end

  def trip_url(handle)
    return nil unless handle.is_a?(String) && handle.match?(HANDLE)

    "https://www.sherpaholidays.com/products/#{handle}"
  end

  def interest_label(code) = INTERESTS[code]
  def interest_labels(codes) = Array(codes).filter_map { |code| INTERESTS[code] }
  def pace_label(value) = PACES[value]
  def length_label(value) = LENGTHS[value]
  def season_label(value) = SEASONS[value]

  def intent_label(value, call_request: nil)
    return "Email their match and a free call" if value == "email" && call_request.present?
    return "Free call" if value == "call" || call_request.present?

    INTENTS[value]
  end

  # One short line per answer, split into the answers the matched trip meets
  # (fits) and the ones it does not (misses), restating only the trip's own
  # tags, experience level, day count and best season, plus the
  # private-journey fact shared by every SherpaHolidays trip.
  def answer_fit(quiz)
    fits = []
    misses = []
    return { fits: fits, misses: misses } unless quiz.is_a?(Hash)

    handle = quiz.dig("match", "handle").to_s
    trip = TRIPS[handle]

    if trip
      Array(quiz["interests"]).each do |code|
        label = INTERESTS[code]
        next unless label

        reason = interest_reason(code, handle, trip)
        if reason
          fits << "#{label}: #{reason}"
        else
          misses << "#{label}: Not on this trip"
        end
      end

      if (pace_label = PACES[quiz["pace"]]) && (trip_rank = LEVEL_RANKS[trip[:level]])
        diff = trip_rank - PACE_RANKS[quiz["pace"]]
        (diff.zero? ? fits : misses) << "#{pace_label}: #{pace_reason(trip[:level], diff)}"
      end

      days = trip[:days].to_i
      if days.positive? && quiz["length"] == "not_sure"
        fits << "Length: #{days} days"
      elsif days.positive? && (len_label = LENGTHS[quiz["length"]])
        (LENGTH_DAYS[quiz["length"]].cover?(days) ? fits : misses) << "#{len_label}: #{days} days"
      end

      if trip[:season].present? && quiz["season"] == "not_sure"
        fits << "When: Best season #{trip[:season]}"
      elsif trip[:season].present? && (short_season = SEASON_SHORT_LABELS[quiz["season"]])
        in_season = TRIP_SEASONS.fetch(trip[:season], []).include?(quiz["season"])
        (in_season ? fits : misses) << "#{short_season}: Best season #{trip[:season]}"
      end
    end

    if (group = quiz["group_size"]).is_a?(Integer) && group.positive?
      fits << "#{group} #{group == 1 ? 'traveler' : 'travelers'}: Every journey is private"
    end

    { fits: fits, misses: misses }
  end

  def interest_reason(code, handle, trip)
    tags = Array(trip[:tags])
    case code
    when "everest"
      "Includes the Everest region" if tags.include?("Everest Region")
    when "temples"
      if tags.include?("Kathmandu Valley")
        "Includes the Kathmandu Valley"
      elsif tags.include?("Cultural Tour")
        "A cultural tour"
      end
    when "mountain-views"
      if handle.include?("mountain-views")
        "A mountain views tour"
      elsif tags.include?("Pokhara")
        "Includes Pokhara"
      end
    when "jungle-safari"
      if tags.include?("Chitwan") && tags.include?("Wildlife Safari")
        "Includes Chitwan and a wildlife safari"
      elsif tags.include?("Wildlife Safari")
        "Includes a wildlife safari"
      elsif tags.include?("Chitwan")
        "Includes Chitwan"
      end
    when "himalayan-trek"
      "A trekking trip" if tags.include?("Trekking")
    when "lumbini"
      "Includes Lumbini" if tags.include?("Lumbini")
    when "peak"
      "A Himalayan peak climb" if tags.include?("Peak Climbing")
    when "rafting"
      "A rafting trip" if tags.include?("Rafting")
    when "beyond"
      if tags.include?("Tibet")
        "Includes Tibet"
      elsif tags.include?("Bhutan")
        "Includes Bhutan"
      elsif tags.include?("India")
        "Includes India"
      end
    when "remote"
      "In a restricted region" if tags.include?("Restricted Region")
    end
  end
  private_class_method :interest_reason

  def pace_reason(level, diff)
    return "Rated #{level}" if diff.zero?

    steps = case diff.abs
    when 1 then "a step"
    when 2 then "two steps"
    else "three steps"
    end
    "Rated #{level}, #{steps} #{diff.positive? ? 'harder' : 'easier'}"
  end
  private_class_method :pace_reason

  def interests(value)
    raise ArgumentError, "quiz.interests" unless value.is_a?(Array) &&
      value.size.between?(1, 3) &&
      value.uniq.size == value.size &&
      value.all? { |item| INTERESTS.key?(item) }

    value
  end
  private_class_method :interests

  def alternates(value)
    raise ArgumentError, "quiz.alternates" unless value.is_a?(Array) && value.size <= MAX_ALTERNATES

    value.map { |item| trip_ref(item, "quiz.alternates") }
  end
  private_class_method :alternates

  def trip_ref(value, field)
    raise ArgumentError, field unless value.is_a?(Hash)

    {
      "handle" => handle(value["handle"], "#{field}.handle"),
      "title" => text(value["title"], 200, "#{field}.title")
    }
  end
  private_class_method :trip_ref

  def handle(value, field)
    raise ArgumentError, field unless value.is_a?(String) && value.match?(HANDLE)

    value
  end
  private_class_method :handle

  def source(value)
    raise ArgumentError, "quiz.source" unless value.is_a?(String) && value.match?(SOURCE)

    value
  end
  private_class_method :source

  def text(value, max, field)
    raise ArgumentError, field unless value.is_a?(String)

    cleaned = value.squish.tr("\u2013\u2014", "--")
    raise ArgumentError, field unless Leads::Itinerary.safe_text?(cleaned, max)

    cleaned
  end
  private_class_method :text

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
    field = "quiz.share_url"
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
