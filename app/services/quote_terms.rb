# frozen_string_literal: true

# Released sources stay in their version directory. Never edit a released
# version; a new release gets a new directory. Quotes store the delivered bytes.
class QuoteTerms
  VERSION = "SH-TC-2026-10-04".freeze
  DISCLOSURE_VERSION = "SH-DISC-2026-10-04".freeze
  ROOT = Rails.root.join("config/booking_terms", VERSION)
  BOND_EXPIRES_ON = Date.new(2027, 3, 7)
  FIELDS = {
    "travelers" => "Booking reference and travelers",
    "start_place" => "Trip start: date and place",
    "end_place" => "Trip end: date and place",
    "operator_services" => "Local operator: full legal name and services provided",
    "air_sea_services" => "Air or sea providers and services sold with the journey",
    "air_sea_departures" => "Each included air/sea departure: date, time and place, or circumstances under which these will be determined",
    "services" => "Services, occupancy, inclusions and exclusions",
    "paid_to_date" => "Amount paid to date",
    "payment_purpose" => "Payment requested now: amount and purpose",
    "passenger_location" => "Passenger location at sale",
    "payer_location" => "Payer location at sale and applicable payment",
    "fund_reason" => "Transaction-specific reason",
    "security_evidence" => "Verified customer-fund security evidence (LLC rider, filed signature and current term)",
    "oral_notice" => "Applicable oral TCRF disclosure given by and at",
    "release_arrangements" => "Participant release arrangements"
  }.freeze

  def self.source(name)
    ROOT.join("#{name}.md").read
  end

  def self.excerpt(name)
    source("replacement-library").split("## #{name}\n", 2).last.split("\n## ", 2).first.strip
  end

  def self.deposit_minor(quote, on: Date.current)
    return nil unless quote.departure_start_on && quote.party_size && %w[scheduled private].include?(quote.journey_kind)
    return quote.total_minor if quote.departure_start_on <= on + 90

    quote.journey_kind == "private" ? (quote.total_minor * 30 + 50) / 100 : 50_000 * quote.party_size
  end

  def self.paid_minor(quote)
    QuoteMoney.parse(quote.disclosure_details&.dig("paid_to_date").to_s.strip)
  end

  def self.payment_now_minor(quote)
    [ quote.deposit_minor - paid_minor(quote).to_i, 0 ].max
  end

  def self.remaining_balance_minor(quote)
    [ quote.total_minor - paid_minor(quote).to_i - payment_now_minor(quote), 0 ].max
  end

  def self.bundle(quote)
    details = quote.disclosure_details
    master = source("master-terms").sub("[verified operator legal name]", quote.local_operator)
    disclosure = source("pre-payment-disclosure")
    values = {
      "Booking reference and travelers" => "#{quote.reference}: #{details.fetch('travelers')}",
      "Journey and scheduled/private classification" => "#{quote.subject_label}, #{quote.journey_kind}",
      "Trip start: date and place" => "#{quote.departure_start_on}: #{details.fetch('start_place')}",
      "Trip end: date and place" => "#{quote.departure_end_on}: #{details.fetch('end_place')}",
      "Final itinerary and quote: attached version and date" => "#{quote.reference}, revision #{quote.version}, #{Date.current}",
      "Local operator: full legal name and services provided" => "#{quote.local_operator}: #{details.fetch('operator_services')}",
      "Air or sea providers and services sold with the journey" => details.fetch("air_sea_services"),
      FIELDS.fetch("air_sea_departures") => details.fetch("air_sea_departures"),
      "Services, occupancy, inclusions and exclusions" => details.fetch("services"),
      "Itemized price, supplements and mandatory charges" => quote.lines.map { |line| "#{line.description}: #{line.quantity} x #{money(line.unit_minor)} = #{money(line.total_minor)}" }.join("; "),
      "Total price in US dollars" => money(quote.total_minor),
      "Amount paid to date" => money(paid_minor(quote)),
      "Payment requested now: amount and purpose" => "#{money(payment_now_minor(quote))}: #{details.fetch('payment_purpose')}",
      "Itemized remaining balance" => money(remaining_balance_minor(quote)),
      "Each future payment: amount and exact due date" => remaining_balance_minor(quote).positive? ? "#{money(remaining_balance_minor(quote))}, due #{quote.balance_due_on}" : "None",
      "Trip-specific differences: affected provision, supplier, amount and effect, or “None”" => quote.trip_differences
    }
    values.each do |label, value|
      cell = value.to_s.gsub(/\s*\n+\s*/, "; ")
      disclosure = disclosure.sub("| #{label} | ____________________ |", "| #{label} | #{cell} |")
    end
    %w[passenger_location payer_location].each do |key|
      disclosure = disclosure.sub("#{FIELDS.fetch(key)}: ____________________", "#{FIELDS.fetch(key)}: #{details.fetch(key)}")
    end
    covered = details.fetch("fund_notice") == "covered"
    disclosure = disclosure.sub("Applicable transaction notice, supplied below: ____________________", "Applicable transaction notice, supplied below: #{covered ? 'Covered' : 'Not covered'}; #{details.fetch('fund_reason')}")
    if covered
      disclosure = disclosure.sub(/### Notice for a transaction not covered by the fund\n.*?(?=## Insurance)/m, "")
    else
      disclosure = disclosure.sub(/### Notice for a covered transaction\n.*?(?=### Notice for a transaction not covered)/m, "")
      disclosure = disclosure.sub("Transaction-specific reason: ____________________", "Transaction-specific reason: #{details.fetch('fund_reason')}")
    end
    # The activity document is handled separately, not falsely attached here.
    disclosure = disclosure.sub("The attached separate participant risk release", "The separate participant risk release")
    # This quote acceptance is not a personal activity signature or a charge mandate.
    disclosure = disclosure.sub(/## Receipt and acceptance\n.*/m, <<~TEXT)
      ## Receipt and acceptance

      Quote acceptance records receipt of this disclosure, quote, master terms and listed differences. It does not sign another adult's release or authorize a payment charge. Mandatory rights remain in effect.

      Participant release arrangements: #{details.fetch('release_arrangements')}
      Applicable oral TCRF disclosure given by and at: #{details.fetch('oral_notice')}
    TEXT
    {
      "terms_version" => VERSION, "disclosure_version" => DISCLOSURE_VERSION,
      "quote_reference" => quote.reference, "quote_revision" => quote.version,
      "paid_to_date_minor" => paid_minor(quote), "payment_now_minor" => payment_now_minor(quote),
      "remaining_balance_minor" => remaining_balance_minor(quote),
      "delivered_at" => Time.current.iso8601,
      "client" => quote.owner_name, "email" => quote.owner_email,
      "master_terms" => master, "pre_payment_disclosure" => disclosure,
      "trip_differences" => quote.trip_differences,
      "itinerary" => "#{quote.subject_label}\n#{quote.departure_start_on} to #{quote.departure_end_on}\n#{quote.included}\n#{quote.notes}\n#{details.fetch('services')}",
      "security_evidence" => details.fetch("security_evidence")
    }
  end

  def self.money(minor)
    "$#{format('%.2f', minor.to_i / 100.0)}"
  end
end
