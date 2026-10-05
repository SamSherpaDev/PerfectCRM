# Mirror of one PerfectBook booking plus its invoice badge. Read-only
# locally: replaced by PerfectBook::SyncBookingsJob, never edited here.
module PerfectBook
  class Booking < ApplicationRecord
    # Tracked traveler document types, matching PerfectBook's sibling API
    # ("API for sibling apps": passport, visa, insurance, waiver).
    DOCUMENT_TYPES = %w[passport visa insurance waiver].freeze
    # Nudge-worthy statuses from the sibling API.
    MISSING_STATUSES = %w[missing expiring].freeze

    scope :available, -> { where(unavailable_at: nil) }

    def available?
      unavailable_at.nil?
    end

    serialize :documents_json, coder: JSON
    serialize :checklist_json, coder: JSON
    serialize :cash_events_json, coder: JSON
    has_one :inquiry_binding, class_name: "::BookingInquiryBinding", foreign_key: :perfectbook_id, primary_key: :perfectbook_id

    def primary_inquiry
      return nil if binding_issue.present?
      inquiry_binding&.lead
    end

    def cash_events
      Array(cash_events_json)
    end

    def receipt_time
      first_received_at
    end

    validates :perfectbook_id, presence: true, uniqueness: true
    validates :perfectbook_contact_id, presence: true

    # first_paid_at is legacy sync-observation evidence only. Never fabricate
    # a payment timestamp from a refresh; authoritative receipts arrive upstream.

    # Per-traveler document rows from the mirrored summary:
    # [{ "id", "first_name", "documents" => [{ "type", "status", "received_at" }] }].
    def travelers
      Array(documents_json.is_a?(Hash) ? documents_json["travelers"] : nil)
    end

    def outstanding_count
      self[:missing_count].to_i
    end

    # "Ama: passport, insurance; Tashi: waiver" for nudge copy, or nil
    # when nothing is outstanding.
    def missing_lines
      lines = travelers.filter_map do |traveler|
        missing = Array(traveler["documents"]).select do |doc|
          MISSING_STATUSES.include?(doc["status"].to_s)
        end
        next if missing.empty?

        types = missing.map { |doc| doc["type"].to_s }. & DOCUMENT_TYPES
        next if types.empty?

        "#{traveler['first_name'].presence || 'Traveler'}: #{types.join(', ')}"
      end
      lines.presence
    end

    def documents_ready?
      documents_summary_present?
    end

    private

    def documents_summary_present?
      documents_json.is_a?(Hash) && documents_json.key?("travelers")
    end
  end
end
