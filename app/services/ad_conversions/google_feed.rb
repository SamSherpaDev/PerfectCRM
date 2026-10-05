# frozen_string_literal: true

require "csv"

module AdConversions
  module GoogleFeed
    HEADERS = [
      "Google Click ID", "Email", "Phone Number", "Conversion Name",
      "Conversion Time", "Conversion Value", "Conversion Currency", "Order ID"
    ].freeze
    USERNAME = "sherpaholidays"

    module_function

    def rows(now: Time.current)
      AdConversion.for_google.includes(lead: :tags)
        .where(delivery_status: %w[not_sent rejected])
        .order(:occurred_at, :id)
        .select { |row| servable?(row, now) }
    end

    def servable?(row, now)
      reason = skip_reason(row, now)
      row.update_column(:google_skip_reason, reason) if row.google_skip_reason != reason
      reason.nil?
    end

    def skip_reason(row, now)
      return "Delivery already accepted or unknown; review platform history" if row.possibly_delivered?
      lead = row.lead
      return "No measurement/sharing permission or excluded inquiry" if AdConversions.excluded?(lead)
      booking_issue = AdConversions.booking_skip_reason(row)
      return booking_issue if booking_issue
      clicked = AdConversions.click_at(lead)
      return "Click observation time missing" if clicked.nil?
      return "Event precedes click or is in the future" if row.occurred_at < clicked || row.occurred_at > now || clicked > now
      window = AdConversions.google_click_ids(lead)["gclid"].present? ? AdConversions::GCLID_WINDOW : AdConversions::ENHANCED_WINDOW
      return "Expired click (#{window.in_days.to_i}-day import window)" if clicked < now - window
      return "Missing matching email/phone" if AdConversions.google_click_ids(lead)["gclid"].blank? &&
        (AdConversions.contact_email(lead) || AdConversions.contact_phone(lead)).blank?
      nil
    end

    def csv(rows)
      CSV.generate do |out|
        out << [ "Parameters:TimeZone=#{AdConversions::TIME_ZONE}" ]
        out << HEADERS
        rows.each { |row| out << line(row) }
      end
    end

    def line(row)
      lead = row.lead
      [
        AdConversions.google_click_ids(lead)["gclid"],
        AdConversions.google_email_hash(AdConversions.contact_email(lead)),
        AdConversions.google_phone_hash(AdConversions.contact_phone(lead)),
        row.google_conversion_name,
        row.occurred_at.in_time_zone(AdConversions::TIME_ZONE).strftime("%Y-%m-%d %H:%M:%S"),
        format("%.2f", row.value_dollars),
        row.currency,
        row.event_id
      ]
    end

    # One authenticated pull: builds the file and records what was served.
    def serve!(settings: Setting.current, now: Time.current)
      served = rows(now: now)
      AdConversion.transaction do
        served = served.filter_map do |row|
          row.lock!
          next unless servable?(row, now)
          row.update!(
            delivery_status: "accepted", last_skip_reason: nil,
            google_first_served_at: row.google_first_served_at || now,
            google_last_served_at: now,
            google_serve_count: row.google_serve_count + 1
          )
          row
        end
        body = csv(served)
        settings.update_columns(google_feed_last_fetched_at: now, google_feed_last_row_count: served.size, updated_at: now)
        body
      end
    end
  end
end
