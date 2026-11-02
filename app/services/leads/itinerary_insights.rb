# The monthly "What people build" view (README.md, "Leads"): what itinerary
# designer visitors picked in one calendar month, Pacific time. Spam and test
# inquiries stay out. Each list is [[label, count]], biggest first.
class Leads::ItineraryInsights
  TIME_ZONE = "America/Los_Angeles".freeze
  TOP = 10
  # Below this, "in every itinerary" says little, so no stop is left out of
  # the combinations.
  ANCHOR_MINIMUM = 5
  NOT_GIVEN = "Not given".freeze

  attr_reader :month

  def initialize(month:)
    @month = month.to_date.beginning_of_month
  end

  def range
    month.in_time_zone(TIME_ZONE).beginning_of_day..month.end_of_month.in_time_zone(TIME_ZONE).end_of_day
  end

  def leads
    @leads ||= begin
      tests = Client.where(is_test: true).select(:id)
      test_inquiries = Lead.where(converted_client_id: tests).or(Lead.where(existing_client_id: tests)).select(:id)
      Lead.where(placement: "itinerary_designer", is_test: false)
        .where.not(id: test_inquiries).where.not(id: Lead.spam.select(:id))
        .where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", range.first, range.last)
        .select { |lead| lead.itinerary }
    end
  end

  def itineraries
    @itineraries ||= leads.map(&:itinerary)
  end

  def built = itineraries.size
  def call_requests = leads.count(&:call_request)
  def email_list = itineraries.count { |itinerary| itinerary["email_list"] == true }

  def stops
    top(tally_titles(itineraries.map { |itinerary| stop_titles(itinerary) }))
  end

  # Pairs of stops built into the same itinerary, in two or more itineraries.
  # Once a month has ANCHOR_MINIMUM itineraries, stops in every one of them
  # (the Kathmandu start, say) are left out so the pairs show real choices.
  def combinations
    titles = itineraries.map { |itinerary| stop_titles(itinerary) }
    everywhere = titles.size >= ANCHOR_MINIMUM ? titles.map { |list| list.map(&:downcase) }.reduce(:&) : []
    pairs = titles.map do |list|
      kept = list.reject { |title| everywhere.include?(title.downcase) }
      kept.combination(2).map { |pair| pair.sort_by(&:downcase).join(" + ") }
    end
    top(tally_titles(pairs).select { |_, count| count >= 2 })
  end

  def base_trips
    top(tally_titles(itineraries.map { |itinerary| [ itinerary.dig("base_trip", "title").presence || itinerary.dig("base_trip", "handle") || NOT_GIVEN ] }))
  end

  def interests
    top(tally_titles(itineraries.map { |itinerary| Array(itinerary["interests"]) }))
  end

  def lengths
    itineraries.group_by { |itinerary| itinerary["length_days"] }
      .sort_by { |days, _| days || Float::INFINITY }
      .map { |days, list| [ Leads::Itinerary.length_label(days)&.upcase_first || NOT_GIVEN, list.size ] }
  end

  def seasons = choices("season", Leads::Itinerary::SEASONS)
  def paces = choices("pace", Leads::Itinerary::PACES)

  def sources
    counts = itineraries.map { |itinerary| Leads::Itinerary.source_label(itinerary["source"]) || NOT_GIVEN }.tally
    counts.sort_by { |label, count| [ -count, label == NOT_GIVEN ? 1 : 0, label ] }
  end

  private

  # Distinct titles per itinerary, so a stop listed twice counts once.
  def stop_titles(itinerary)
    itinerary["stops"].map { |stop| stop["title"].to_s.squish }.uniq(&:downcase)
  end

  # Counts each label once per itinerary, case-insensitively, keeping the
  # first spelling seen.
  def tally_titles(lists)
    spelling = {}
    counts = Hash.new(0)
    lists.each do |list|
      list.uniq(&:downcase).each do |label|
        key = label.downcase
        spelling[key] ||= label
        counts[key] += 1
      end
    end
    counts.map { |key, count| [ spelling[key], count ] }
  end

  def top(rows)
    rows.sort_by { |label, count| [ -count, label.downcase ] }.first(TOP)
  end

  # Every choice in the designer's order, zeros included, then any blanks.
  def choices(key, labels)
    counts = itineraries.map { |itinerary| itinerary[key] }.tally
    rows = labels.map { |value, label| [ label, counts.fetch(value, 0) ] }
    rows << [ NOT_GIVEN, counts[nil] ] if counts[nil]
    rows
  end
end
