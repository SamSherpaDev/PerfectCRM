# frozen_string_literal: true

# Live values for {{placeholders}}: the deferred half of the templates
# task. Built from the CRM record plus the mirrored PerfectBook booking,
# so a template inserted in the reply box arrives already filled.
#
# Values that are unknown or empty are left OUT on purpose: the renderer
# turns them into the visible [missing: name] marker instead of a silent
# blank (correction A from the templates review).
class TemplateContext
  INACTIVE_BOOKING_STATUSES = %w[cancelled voided refunded].freeze

  def self.for_recipient(recipient, departure_id: nil)
    owner = Outbound::OwnerLookup.for_email(recipient.email)
    return owner ? self.for(owner) : {} if departure_id.blank?

    contact = PerfectBook::Contact.find_by("lower(email) = ?", recipient.email.strip.downcase)
    contact_id = owner.try(:perfectbook_contact_id).presence || contact&.perfectbook_id
    booking = PerfectBook::Booking.where(departure_id: departure_id, perfectbook_contact_id: contact_id).order(:id).first if contact_id
    context = self.for(owner || contact || recipient, booking: nil)
    context.merge!(booking_context(booking).compact_blank) if booking
    context
  end

  def self.for(record, booking: default_booking_for(record))
    context = {
      "first_name" => first_name_for(record),
      "full_name" => record.name.to_s,
      "advisor_name" => advisor_name_for(record),
      "my_name" => Setting.current.sender_name.presence,
      "signature" => Setting.current.email_signature.presence
    }
    context.merge!(booking_context(booking)) if booking
    context.compact_blank
  end

  # Every mirrored booking this record could fill placeholders from, best
  # first. The reply box offers the rest in a select when several exist.
  def self.bookings_for(record)
    contact_id = record.try(:perfectbook_contact_id)
    return [] if contact_id.blank?

    rows = PerfectBook::Booking.where(perfectbook_contact_id: contact_id).to_a
    rows.sort_by do |row|
      [ INACTIVE_BOOKING_STATUSES.include?(row.status.to_s) ? 1 : 0,
        row.start_date ? 0 : 1,
        row.start_date ? -row.start_date.to_time.to_i : 0,
        -row.id ]
    end
  end

  def self.default_booking_for(record)
    bookings_for(record).first
  end

  def self.first_name_for(record)
    record.name.to_s.split.first.to_s.presence
  end

  def self.advisor_name_for(record)
    record.try(:referred_by_organization)&.name.presence
  end

  def self.booking_context(booking)
    {
      "trip" => booking.trip_name.presence,
      "departure_dates" => departure_dates_for(booking),
      "balance_due" => money_for(booking.balance_due_minor, booking.currency),
      "deposit_due" => nil,
      "invoice_number" => booking.invoice_number.presence,
      "payment_reference" => booking.payment_reference.presence,
      "missing_documents" => nil
    }
  end

  def self.departure_dates_for(booking)
    start_date = booking.start_date
    end_date = booking.end_date
    return nil if start_date.blank? && end_date.blank?
    return end_date.strftime("%b %-d, %Y") if start_date.blank?
    return start_date.strftime("%b %-d, %Y") if end_date.blank?
    if start_date.year == end_date.year
      "#{start_date.strftime('%b %-d')} – #{end_date.strftime('%b %-d, %Y')}"
    else
      "#{start_date.strftime('%b %-d, %Y')} – #{end_date.strftime('%b %-d, %Y')}"
    end
  end

  def self.money_for(minor, currency)
    return nil if minor.nil?

    minor = minor.to_i
    amount = ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", minor.abs / 100.0))
    amount = "-#{amount}" if minor.negative?
    currency.blank? || currency == "USD" ? "$#{amount}" : "#{currency} #{amount}"
  end
  private_class_method :first_name_for, :advisor_name_for, :booking_context,
    :departure_dates_for, :money_for
end
