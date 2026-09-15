# One board column per trail stage: leads for new..lost, clients for
# won and post_trip. Filters narrow the lead columns (and the client
# columns where the field exists); counts and money sums ride along.
class Pipeline::Board
  STAGES = %w[new chatting quoted nudged won post_trip lost].freeze
  LEAD_STAGES = %w[new chatting quoted nudged lost].freeze
  CLIENT_STAGES = %w[won post_trip].freeze

  Column = Data.define(:stage, :records, :count, :value_minor)

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
          count: scope.count, value_minor: scope.sum(:expected_value_minor).to_i)
      else
        scope = filtered_clients(Client.in_stage(stage))
        Column.new(stage: stage, records: scope.ordered.includes(:tags, :people).to_a,
          count: scope.count, value_minor: 0)
      end
    end
  end

  def trip_options
    Lead.where(converted_client_id: nil).where.not(trip_interest: [ nil, "" ])
      .distinct.order(:trip_interest).pluck(:trip_interest)
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
    scope
  end
end
