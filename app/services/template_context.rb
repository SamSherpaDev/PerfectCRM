# frozen_string_literal: true

# Recipient and booking context for operational template rendering.
# Resolution policy: see README.md, "Replying".
#
# Values that are unknown or empty are left OUT on purpose: the renderer
# turns them into the visible [missing: name] marker instead of a silent
# blank.
class TemplateContext
  INACTIVE_BOOKING_STATUSES = %w[cancelled voided refunded].freeze

  def self.resolve_recipient(recipient, owner: nil)
    email = recipient.email.to_s.strip.downcase
    begin
      owner = Outbound::OwnerLookup.for_email(email) || owner
    rescue Outbound::OwnerLookup::Conflict
      raise unless owner
    end
    contact = PerfectBook::Contact.find_by("lower(email) = ?", email) if email.present?
    person = Person.find_by("lower(email) = ?", email) if email.present?
    identity = contact || person || (owner if email.blank? || owner.try(:email).to_s.downcase == email) || recipient
    contact_id = contact ? contact.perfectbook_id : owner.try(:perfectbook_contact_id)
    { identity: identity, owner: owner, recipient_email: email, bookings: bookings_for_contact(contact_id), fallback: contact.nil? }
  end

  def self.resolved_context(resolved, booking)
    identity = resolved[:identity]
    context = self.for(identity, booking: booking)
    owner = resolved[:owner]
    if owner.is_a?(Lead) && resolved[:recipient_email].present? &&
        owner.email.to_s.strip.downcase == resolved[:recipient_email] && owner.trip_interest.present?
      context["trip"] ||= owner.trip_interest
    end
    context["advisor_name"] = advisor_name_for(owner) if advisor_name_for(owner).present?
    context["booking_owner_name"] = owner.name if booking && resolved[:fallback] && owner
    context
  end

  def self.for_document_nudge(record, booking)
    template = Template.active.for_purpose(:document_request).ordered.first
    context = self.for(record, booking: booking)
    context["missing_documents"] ||= booking.try(:missing_lines)&.join("; ") ||
      "[Check missing documents in PerfectBook]"
    subject = TemplateRenderer.render(template&.subject.presence || "Documents for {{trip}}", context)
    body_template = template&.body.presence ||
      "Hi {{first_name}},\n\nPlease send these missing documents through PerfectBook: {{missing_documents}}.\n\n{{signature}}"
    body = TemplateRenderer.render(body_template, context)
    dates = booking.start_date || booking.end_date ? departure_dates_for(booking) : nil
    body += "\n\n#{record.name} · #{booking.trip_name}\n#{dates}\nBooking: #{booking.ref}"
    { template: template, subject: subject, body: body, context: context }
  end

  def self.for_recipient(recipient, departure_id: nil)
    resolved = resolve_recipient(recipient)
    bookings = resolved[:bookings]
    booking = departure_id.present? ? bookings.find { |row| row.departure_id.to_s == departure_id.to_s } : bookings.first
    resolved_context(resolved, booking)
  end

  def self.for_reply(to:, owner:, booking_id: nil)
    address = to.to_s.split(/[,;\n]/).first.to_s.strip
    parsed = MergeBatch.parse_recipients(address).first
    recipient = parsed || MergeBatch::Recipient.new(name: nil, email: address)
    resolved = resolve_recipient(recipient, owner: owner)
    bookings = resolved[:bookings]
    selected = bookings.find { |booking| booking.perfectbook_id.to_s == booking_id.to_s } || bookings.first
    {
      context: resolved_context(resolved, selected),
      selected_booking_id: selected&.perfectbook_id,
      bookings: bookings.map do |booking|
        { id: booking.perfectbook_id, label: "#{booking.trip_name.presence || 'Booking'} · #{booking.ref.presence || booking.invoice_number.presence || "##{booking.perfectbook_id}"}" }
      end,
      booking_contexts: bookings.to_h { |booking| [ booking.perfectbook_id, resolved_context(resolved, booking) ] }
    }
  end

  def self.for(record, booking: default_booking_for(record))
    context = {
      "first_name" => first_name_for(record),
      "full_name" => record.name.to_s,
      "advisor_name" => advisor_name_for(record),
      "my_name" => Setting.current.sender_name.presence,
      "signature" => EmailSignature.text_for(Setting.current).presence
    }
    context.merge!(booking_context(booking)) if booking
    context.compact_blank
  end

  # Every mirrored booking this record could fill placeholders from, best
  # first. The reply box offers the rest in a select when several exist.
  def self.bookings_for(record)
    bookings_for_contact(record.try(:perfectbook_contact_id))
  end

  def self.bookings_for_contact(contact_id)
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
      "missing_documents" => booking.respond_to?(:missing_lines) ? booking.missing_lines&.join("; ") : nil
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
