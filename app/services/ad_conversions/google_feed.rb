# frozen_string_literal: true

require "csv"

module AdConversions
  # The CSV Google Ads pulls on its own daily schedule (Goals > Uploads >
  # Schedules, source HTTPS). Offline click conversions plus hashed email
  # and phone for enhanced conversions for leads. Each row stays in the file
  # for REPEAT_WINDOW after Google first fetches it, so one failed pull
  # loses nothing; Google ignores the repeats as duplicates (same Order ID).
  module GoogleFeed
    HEADERS = [
      "Google Click ID", "Email", "Phone Number", "Conversion Name",
      "Conversion Time", "Conversion Value", "Conversion Currency", "Order ID"
    ].freeze
    USERNAME = "sherpaholidays"
    REPEAT_WINDOW = 3.days

    module_function

    def rows(now: Time.current)
      AdConversion.for_google.includes(lead: :tags)
        .where("google_first_served_at IS NULL OR google_first_served_at >= ?", now - REPEAT_WINDOW)
        .order(:occurred_at, :id)
        .select { |row| servable?(row, now) }
    end

    def servable?(row, now)
      lead = row.lead
      return false if AdConversions.excluded?(lead)

      clicked = AdConversions.click_at(lead)
      if AdConversions.google_click_ids(lead)["gclid"].present?
        clicked >= now - AdConversions::GCLID_WINDOW
      else
        clicked >= now - AdConversions::ENHANCED_WINDOW &&
          (AdConversions.contact_email(lead) || AdConversions.contact_phone(lead)).present?
      end
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
      body = csv(served)
      AdConversion.transaction do
        served.each do |row|
          row.update!(
            google_first_served_at: row.google_first_served_at || now,
            google_last_served_at: now,
            google_serve_count: row.google_serve_count + 1
          )
        end
        settings.update_columns(google_feed_last_fetched_at: now, google_feed_last_row_count: served.size, updated_at: now)
      end
      body
    end
  end
end
