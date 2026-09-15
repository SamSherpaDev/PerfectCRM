# frozen_string_literal: true

# Facts handed to the model: thread text, the linked record, mirrored
# PerfectBook booking facts, and the captain's voice (his templates as
# style examples plus the short guide in Settings). Only text and facts;
# never attachments or document bytes.
module Ai
  module Context
    THREAD_LIMIT = 12
    BODY_LIMIT = 1200

    def self.thread_text(conversation)
      conversation.messages.reorder(sent_at: :desc, id: :desc).limit(THREAD_LIMIT).to_a.reverse.map do |message|
        who = message.direction == "in" ? "Client" : "Captain"
        date = message.sent_at ? message.sent_at.strftime("%b %-d") : "undated"
        body = message_body(message)
        "#{who} (#{date}): #{body.truncate(BODY_LIMIT)}"
      end.join("\n\n")
    end

    def self.message_body(message)
      text = message.text_body.presence ||
        Loofah.html5_fragment(message.html_body.to_s).scrub!(:prune).to_text(encode_special_chars: false).squish
      Scrub.scrub(text)
    end

    def self.client_facts(record)
      return "No linked record." if record.nil?

      lines = [ "Name: #{record.name}" ]
      lines << "Email: #{record.try(:email)}" if record.try(:email).present?
      if record.is_a?(::Lead)
        lines << "Stage: #{record.status}"
        lines << "Source: #{record.source}"
        lines << "Asked about: #{record.try(:asked_about) || record.try(:trip_interest)}" rescue nil
        lines << "Fit: #{record.fit_band} #{record.fit_score} #{record.fit_reason}".strip if record.fit_band.present?
      elsif record.is_a?(::Client)
        lines << "Source: #{record.source}" if record.source.present?
      end
      lines << "Tags: #{record.tags.map(&:name).join(', ')}" if record.respond_to?(:tags) && record.tags.any?
      Scrub.scrub(lines.reject(&:blank?).join("\n"))
    end

    def self.booking_facts(record)
      contact_id = record.try(:perfectbook_contact_id)
      return "No mirrored bookings." if contact_id.blank?

      rows = ::PerfectBook::Booking.where(perfectbook_contact_id: contact_id).limit(3)
      return "No mirrored bookings." if rows.empty?

      rows.map do |booking|
        parts = []
        parts << "Trip: #{booking.try(:trip_name) || booking.try(:trip)}" rescue nil
        parts << "Status: #{booking.status}" if booking.respond_to?(:status) && booking.status.present?
        parts << "Start: #{booking.start_date}" if booking.respond_to?(:start_date) && booking.start_date.present?
        parts << "Balance: #{booking.currency.presence || 'USD'} #{format('%.2f', booking.balance_due_minor.to_d / 100)}" if booking.respond_to?(:balance_due_minor) && !booking.balance_due_minor.nil?
        parts.compact_blank.join(" · ")
      end.join("\n")
    end

    def self.voice_examples(limit: 3)
      ::Template.active.ordered.limit(limit).map do |template|
        "--- #{template.name} ---\n#{Scrub.scrub(template.body.to_s.truncate(600))}"
      end.join("\n\n").presence || "No templates yet."
    end
  end
end
