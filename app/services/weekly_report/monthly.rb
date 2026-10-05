module WeeklyReport
  # Alternatives, not additive attribution. Every booking is counted once in
  # each view; receipt/refund dates and currencies come only from PerfectBook.
  class Monthly
    VIEWS = { "reported" => "Reported discovery", "paid" => "Inquiry paid-performance touch", "first" => "First observed website touch" }.freeze
    HORIZONS = [ 30, 60, 90, 180 ].freeze
    Row = Struct.new(:source, :campaign_id, :campaign, :inquiries, :q_fit, :platform_qualified,
      :connected_calls, :reached_ids, :attempts, :booked, :travelers, :missing_traveler_counts,
      :active, :cancelled, :cancellations_in_month, :returning, :inferred_links, :new_booker_ids, :personal_referrals, :advisor_referrals,
      :booked_value, :receipts, :refunds, :spend, keyword_init: true) do
      def label
        [ source.humanize, campaign.presence || campaign_id ].compact.join(" · ")
      end
      def net_received
        (receipts.keys | refunds.keys).to_h { |currency| [ currency, receipts.fetch(currency, 0) - refunds.fetch(currency, 0) ] }
      end
      def cost_per_booking
        spend&.transform_values { |amount| Summary.ratio(amount, booked) }
      end
      def cost_per_traveler
        spend&.transform_values { |amount| missing_traveler_counts.zero? ? Summary.ratio(amount, travelers) : nil }
      end
    end
    attr_reader :month, :view, :as_of, :end_date

    def initialize(month: Date.current.beginning_of_month, view: "reported", as_of: Time.current)
      @month = month.to_date.beginning_of_month
      @view = VIEWS.key?(view) ? view : "reported"
      @as_of = as_of.in_time_zone("America/Los_Angeles")
      @end_date = [ @month.end_of_month, @as_of.to_date ].min
    end

    def range
      month.in_time_zone("America/Los_Angeles").beginning_of_day..[ month.end_of_month.in_time_zone("America/Los_Angeles").end_of_day, as_of ].min
    end

    def leads
      @leads ||= eligible_leads.where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", range.first, range.last).to_a
    end

    def eligible_leads(include_archived: false)
      tests = Client.where(is_test: true).select(:id)
      test_inquiries = Lead.where(converted_client_id: tests).or(Lead.where(existing_client_id: tests)).select(:id)
      (include_archived ? Lead.all : Lead.active).where(is_test: false).where.not(id: test_inquiries)
        .where.not(id: Tagging.joins(:tag).where(taggable_type: "Lead", tags: { name: Lead::SUSPECTED_SPAM_TAG }).select(:taggable_id))
    end

    def rows
      @rows ||= build_rows
    end

    def source_rows
      return rows unless view == "paid"
      @source_rows ||= rows.group_by(&:source).map do |_, list|
        row = merge_rows(list)
        row.campaign = row.campaign_id = nil
        row
      end
    end

    def totals
      { inquiries: rows.sum(&:inquiries), connected_calls: rows.sum(&:connected_calls),
        bookings: rows.sum(&:booked), travelers: rows.sum(&:travelers),
        net_received: sum_money(rows.map(&:net_received)), booked_value: sum_money(rows.map(&:booked_value)) }
    end

    def completeness
      answered = leads.count { |lead| lead.source_answer_state == "answered" }
      confirmed = leads.count { |lead| lead.source_answer_state == "answered" && lead.source_confirmed_at.present? }
      { inquiries: leads.size, answered: answered, confirmed: confirmed,
        answer_states: leads.group_by(&:source_answer_state).transform_values(&:size),
        unlinked_calls: unlinked_calls.size,
        linked_clients: leads.map { |lead| lead.converted_client_id || lead.existing_client_id }.compact.uniq.size,
        unresolved_identities: leads.count { |lead| lead.converted_client_id.nil? && lead.existing_client_id.nil? },
        fit_unreviewed: leads.count { |lead| lead.owner_fit_at_inquiry.blank? },
        missing_capture: leads.group_by { |lead| lead.metadata&.dig("acquisition", "first_touch", "unknown_reason").presence || (lead.metadata&.dig("acquisition", "first_touch").present? ? "captured" : "legacy_missing") }.transform_values(&:size),
        unlinked_bookings: relevant_bookings.count { |booking| booking.primary_inquiry.nil? },
        inferred_bookings: relevant_bookings.count { |booking| booking.inquiry_binding&.state == "inferred" },
        missing_financial_facts: relevant_bookings.count { |booking| booking.cash_events_json.nil? },
        undated_paid_bookings: countable_bookings.where(first_received_at: nil, first_received_on: nil).where("paid_minor > 0").count,
        unavailable_bookings: relevant_bookings.count { |booking| booking.unavailable_at.present? },
        tests_held: Lead.where(is_test: true).where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", range.first, range.last).count,
        missing_spend: view == "paid" ? rows.count { |row| AdSpend::SOURCES.include?(row.source) && row.spend.nil? } : nil }
    end

    def cohorts
      ids = leads.map(&:id)
      bookings = PerfectBook::Booking.joins(:inquiry_binding).where(booking_inquiry_bindings: { lead_id: ids })
        .where("first_received_at <= ?", as_of).includes(inquiry_binding: :lead).to_a.reject { |booking| booking.binding_issue.present? }
      first_receipts = bookings.group_by { |booking| booking.inquiry_binding.lead_id }.transform_values { |list| list.min_by(&:first_received_at) }
      horizons = HORIZONS.to_h do |days|
        mature = leads.select { |lead| inquiry_time(lead) + days.days <= as_of }
        converted = mature.count do |lead|
          booking = first_receipts[lead.id]
          next false unless booking
          if booking.first_received_precision == "date"
            (inquiry_time(lead).to_date..(inquiry_time(lead) + days.days).to_date).cover?(booking.first_received_on || booking.first_received_at.to_date)
          else
            (inquiry_time(lead)..(inquiry_time(lead) + days.days)).cover?(booking.first_received_at)
          end
        end
        [ days, { eligible: mature.size, booked_inquiries: converted, pending: leads.size - mature.size } ]
      end
      { inquiries: leads.size, horizons: horizons, bookings: bookings.size,
        booked_value: sum_money(bookings.map { |booking| { booking.currency => booking.total_minor.to_i } }),
        net_received: sum_money(bookings.map { |booking| booking.cash_events.select { |event| event_date(event) && event_date(event) <= as_of.to_date && (event["time_precision"] != "timestamp" || Time.iso8601(event["occurred_at"]) <= as_of) }.each_with_object(Hash.new(0)) { |event, sum| sum[event["currency"]] += event["amount_minor"].to_i * (event["kind"] == "refund" ? -1 : 1) } }) }
    end

    private

    def new_row(source, id, name)
      Row.new(source: source, campaign_id: id, campaign: name, inquiries: 0, q_fit: 0, platform_qualified: 0,
        connected_calls: 0, reached_ids: [], attempts: 0, booked: 0, travelers: 0, missing_traveler_counts: 0,
        active: 0, cancelled: 0, cancellations_in_month: 0, returning: 0, inferred_links: 0, new_booker_ids: [], personal_referrals: 0, advisor_referrals: 0,
        booked_value: Hash.new(0), receipts: Hash.new(0), refunds: Hash.new(0))
    end

    def identity(lead)
      return [ "Unlinked booking", nil, nil ] unless lead
      if view == "reported"
        source = lead.source_label || "Not asked yet"
        source += " (provisional)" if lead.source_answer_state == "answered" && lead.source_confirmed_at.nil?
        [ source, nil, nil ]
      else
        touch = lead.metadata&.dig("acquisition", view == "first" ? "first_touch" : "last_non_direct_touch")
        return [ "Unknown (#{touch&.dig('unknown_reason').presence || 'legacy_missing'})", nil, nil ] unless Leads::Acquisition.eligible?(touch)
        [ touch["source"].presence || "Unknown", touch["campaign_id"].presence, touch["utm_campaign"].presence ]
      end
    end

    def build_rows
      index = {}
      row_for = ->(lead) { key = identity(lead); index[key] ||= new_row(*key) }
      leads.each do |lead|
        row = row_for.call(lead)
        row.inquiries += 1
        row.q_fit += 1 if AdConversions::QUALIFIED_BANDS.include?(lead.owner_fit_at_inquiry)
        row.personal_referrals += 1 if lead.referred_by_client_id || lead.referred_by_person_id || lead.reported_source_code == "personal_referral"
        row.advisor_referrals += 1 if lead.referral_code.present? || lead.referred_by_organization_id
      end
      eligible_leads.where(id: platform_ids).each { |lead| row_for.call(lead).platform_qualified += 1 }
      ActivityEvent.where(subject_type: "Lead", subject_id: eligible_leads.select(:id), kind: "call", occurred_at: range).includes(:subject).each do |call|
        row = row_for.call(call.subject)
        if call.metadata["outcome"] == "connected"
          row.connected_calls += 1
          row.reached_ids |= [ call.subject_id ]
        else
          row.attempts += 1
        end
      end
      unlinked_calls.each do |call|
        key = [ "Unknown (call without inquiry)", nil, nil ]
        row = index[key] ||= new_row(*key)
        row.connected_calls += 1 if call.metadata["outcome"] == "connected"
        row.attempts += 1 if (CallLog::OUTCOMES - [ "connected" ]).include?(call.metadata["outcome"])
      end
      relevant_bookings.each do |booking|
        lead = booking.primary_inquiry
        next if excluded_booking?(booking)
        row = row_for.call(lead)
        row.inferred_links += 1 if booking.inquiry_binding&.state == "inferred"
        if deposit_in_month?(booking)
          row.booked += 1
          row.travelers += booking.traveler_count.to_i
          row.missing_traveler_counts += 1 if booking.traveler_count.nil?
          row.booked_value[booking.currency] += booking.total_minor.to_i
          if returning?(booking)
            row.returning += 1
          else
            row.new_booker_ids |= [ booking.perfectbook_contact_id ]
          end
          inactive = booking.cancelled_at.present? || TemplateContext::INACTIVE_BOOKING_STATUSES.include?(booking.status)
          row.cancelled += 1 if inactive
          row.active += 1 if !inactive && booking.status.present? && booking.unavailable_at.nil?
        end
        if booking.cancelled_at && range.cover?(booking.cancelled_at)
          row.cancellations_in_month += 1
        end
        booking.cash_events.each do |event|
          date = event_date(event)
          next unless date && (month..end_date).cover?(date)
          next if event["time_precision"] == "timestamp" && Time.iso8601(event["occurred_at"]) > as_of
          bucket = event["kind"] == "refund" ? row.refunds : row.receipts
          bucket[event["currency"]] += event["amount_minor"].to_i
        end
      end
      if view == "paid"
        spends = DailyAdSpend.where(spent_on: month..end_date).order(:spent_on, :id).to_a
        # Identity is stable campaign ID, not a mutable name. Collapse labels.
        grouped = index.values.group_by { |row| [ row.source, row.campaign_id || "name:#{row.campaign}" ] }
        index = grouped.transform_values { |list| merge_rows(list) }
        spends.group_by { |spend| [ spend.source, spend.campaign_id ] }.each do |key, entries|
          row = index[key] ||= new_row(key.first, key.last, entries.last.campaign_name)
          row.campaign = entries.last.campaign_name
          row.spend = exact_spend(entries)
        end
        AdSpend::SOURCES.each { |source| index[[ source, nil ]] ||= new_row(source, nil, nil) if index.values.none? { |row| row.source == source } }
      end
      index.values.sort_by { |row| [ -row.booked, -row.inquiries, row.label ] }
    end

    def merge_rows(list)
      result = list.first.dup
      %i[reached_ids new_booker_ids booked_value receipts refunds].each { |field| result[field] = result[field].dup }
      result.spend = list.all?(&:spend) ? sum_money(list.map(&:spend)) : nil
      list.drop(1).each do |row|
        %i[inquiries q_fit platform_qualified connected_calls attempts booked travelers missing_traveler_counts active cancelled cancellations_in_month returning inferred_links personal_referrals advisor_referrals].each { |field| result[field] += row[field] }
        result.reached_ids |= row.reached_ids
        result.new_booker_ids |= row.new_booker_ids
        %i[booked_value receipts refunds].each { |field| row[field].each { |currency, amount| result[field][currency] += amount } }
      end
      result
    end

    def exact_spend(entries)
      return nil if end_date < month
      days = (month..end_date).to_a
      currencies = entries.group_by(&:currency)
      return nil unless currencies.values.all? { |list| list.map(&:spent_on).uniq.sort == days }
      currencies.transform_values { |list| list.sum(&:amount_minor) }
    end

    def platform_ids
      candidates = eligible_leads.where(fit_band: AdConversions::QUALIFIED_BANDS).pluck(:id)
      ActivityEvent.where(subject_type: "Lead", subject_id: candidates, kind: "stage_change")
        .order(:occurred_at, :id).each_with_object({}) do |event, first|
        next unless AdConversions::QUALIFIED_STATUSES.include?(event.metadata["to"]) && event.metadata["actor"].present? && event.metadata["actor"] != "automation"
        first[event.subject_id] ||= event.occurred_at
      end.select { |_, at| range.cover?(at) }.keys
    end

    def unlinked_calls
      @unlinked_calls ||= ActivityEvent.where(kind: "call", occurred_at: range).where.not(subject_type: "Lead")
        .where("json_extract(metadata, '$.inquiry_id') IS NULL AND json_extract(metadata, '$.from_lead_event_id') IS NULL")
        .where.not(id: ActivityEvent.where(subject_type: "Client", subject_id: Client.where(is_test: true).select(:id)).select(:id)).to_a
    end

    def countable_bookings
      excluded_ids = BookingInquiryBinding.where.not(lead_id: eligible_leads(include_archived: true).select(:id)).select(:perfectbook_id)
      PerfectBook::Booking.where.not(perfectbook_id: excluded_ids)
    end

    def relevant_bookings
      @relevant_bookings ||= countable_bookings.where("first_received_on BETWEEN :start AND :end OR first_received_at BETWEEN :from AND :to OR cancelled_at BETWEEN :from AND :to OR EXISTS (SELECT 1 FROM json_each(COALESCE(cash_events_json, '[]')) WHERE json_extract(value, '$.occurred_on') BETWEEN :start AND :end)",
        start: month.iso8601, end: end_date.iso8601, from: range.first, to: range.last)
        .includes(inquiry_binding: { lead: [ :tags, :converted_client, :existing_client ] }).to_a
    end

    def excluded_booking?(booking)
      lead = booking.inquiry_binding&.lead
      lead && (lead.is_test? || lead.converted_client&.is_test? || lead.existing_client&.is_test? || lead.suspected_spam?)
    end

    def deposit_in_month?(booking)
      return false if booking.first_received_at && booking.first_received_at > as_of
      date = booking.first_received_on || booking.first_received_at&.in_time_zone("America/Los_Angeles")&.to_date
      date && (month..end_date).cover?(date)
    end

    def returning?(booking)
      @first_bookings ||= PerfectBook::Booking.where(perfectbook_contact_id: relevant_bookings.map(&:perfectbook_contact_id).uniq)
        .where.not(first_received_at: nil).order(:first_received_at, :perfectbook_id)
        .pluck(:perfectbook_contact_id, :perfectbook_id).each_with_object({}) { |(contact, id), first| first[contact] ||= id }
      @first_bookings[booking.perfectbook_contact_id] != booking.perfectbook_id
    end

    def inquiry_time(lead) = lead.received_at || lead.created_at

    def event_date(event)
      Date.iso8601(event["occurred_on"].to_s)
    rescue Date::Error
      nil
    end

    def sum_money(list)
      list.each_with_object(Hash.new(0)) { |money, sum| money.each { |currency, amount| sum[currency] += amount } }
    end
  end
end
