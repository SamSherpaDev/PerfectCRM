# Mirror of one PerfectBook booking plus its invoice badge. Read-only
# locally: replaced by PerfectBook::SyncBookingsJob, never edited here.
# TODO: record an ActivityEvent when status or invoice_badge changes, once
# that model lands on main (no such model yet, so syncs stay silent).
module PerfectBook
  class Booking < ApplicationRecord
    # Tracked traveler document types, matching PerfectBook's sibling API
    # ("API for sibling apps": passport, visa, insurance, waiver).
    DOCUMENT_TYPES = %w[passport visa insurance waiver].freeze
    # Nudge-worthy statuses: everything except received and not_required.
    MISSING_STATUSES = %w[missing expiring].freeze

    serialize :documents_json, coder: JSON
    serialize :checklist_json, coder: JSON

    validates :perfectbook_id, presence: true, uniqueness: true
    validates :perfectbook_contact_id, presence: true

    # Per-traveler document rows from the mirrored summary:
    # [{ "id", "first_name", "documents" => [{ "type", "status", "received_at" }] }].
    def travelers
      Array(documents_json.is_a?(Hash) ? documents_json["travelers"] : nil)
    end

    # Outstanding documents across all travelers (missing + expiring),
    # excluding received and not_required. Stored at sync; falls back to
    # a live count when the mirror predates the documents summary.
    def outstanding_count
      count = self[:missing_count].to_i
      return count if documents_summary_present? || count.positive?

      live_missing_count
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

    # Flat "passport, insurance, waiver" list across travelers for the
    # {{missing_documents}} placeholder.
    def missing_types
      travelers.flat_map do |traveler|
        Array(traveler["documents"]).select do |doc|
          MISSING_STATUSES.include?(doc["status"].to_s)
        end.map { |doc| doc["type"].to_s }
      end. & DOCUMENT_TYPES
    end

    def traveler_names
      travelers.map { |traveler| traveler["first_name"].presence }.compact_blank.uniq
    end

    def documents_ready?
      documents_summary_present?
    end

    def checklist
      Array(checklist_json)
    end

    private

    def documents_summary_present?
      documents_json.is_a?(Hash) && documents_json.key?("travelers")
    end

    def live_missing_count
      travelers.sum do |traveler|
        Array(traveler["documents"]).count do |doc|
          MISSING_STATUSES.include?(doc["status"].to_s)
        end
      end
    end
  end
end
