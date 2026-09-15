# One board column per trail stage: leads for new..lost, clients for
# won and post_trip. Filters narrow the lead columns (and the client
# columns where the field exists); counts and money sums ride along.
class Pipeline::Board
  STAGES = %w[new chatting quoted nudged won post_trip lost].freeze
  LEAD_STAGES = %w[new chatting quoted nudged lost].freeze
  CLIENT_STAGES = %w[won post_trip].freeze

  Column = Data.define(:stage, :records, :count, :values_by_currency)

  attr_reader :filters

  def initialize(source: nil, trip: nil, advisor: nil)
    @filters = {
      source: source.to_s.strip.presence,
      trip: trip.to_s.strip.presence,
      advisor: advisor.to_s.strip.presence
    }.compact
  end

  def columns
    STAGES.map do |stage|
      if LEAD_STAGES.include?(stage)
        scope = filtered_leads(Lead.by_status(stage))
        Column.new(stage: stage, records: scope.ordered.includes(:tags, :people).to_a,
          count: scope.count, values_by_currency: { "USD" => scope.sum(:expected_value_minor).to_i })
      else
        scope = filtered_clients(Client.in_stage(stage))
        records = scope.ordered.includes(:tags, :people, :perfectbook_bookings, :converted_leads).to_a
        totals = records.each_with_object(Hash.new(0)) do |record, sums|
          record.pipeline_values_by_currency.each { |currency, minor| sums[currency] += minor }
        end
        Column.new(stage: stage, records: records,
          count: records.size, values_by_currency: totals)
      end
    end
  end

  def trip_options
    (Lead.where.not(trip_interest: [ nil, "" ]).distinct.pluck(:trip_interest) +
      PerfectBook::Booking.where.not(trip_name: [ nil, "" ]).distinct.pluck(:trip_name)).uniq.sort
  end

  def advisor_options
    Organization.order(:name).to_a
  end

  private

  def filtered_leads(scope)
    scope = scope.where(source: filters[:source]) if filters[:source]
    scope = scope.where(trip_interest: filters[:trip]) if filters[:trip]
    scope = scope.where(referred_by_organization_id: filters[:advisor]) if filters[:advisor]
    scope
  end

  def filtered_clients(scope)
    scope = scope.where(source: filters[:source]) if filters[:source]
    scope = scope.where(referred_by_organization_id: filters[:advisor]) if filters[:advisor]
    if filters[:trip]
      lead_clients = Lead.converted.where(trip_interest: filters[:trip]).select(:converted_client_id)
      booking_contacts = PerfectBook::Booking.where(trip_name: filters[:trip]).select(:perfectbook_contact_id)
      scope = scope.where(id: lead_clients).or(scope.where(perfectbook_contact_id: booking_contacts))
    end
    scope
  end
end
