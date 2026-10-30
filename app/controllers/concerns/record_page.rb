# The three-column record page for leads and clients (docs/DESIGN.md 4.11,
# README "Leads" and "Clients"): one timeline of email, notes, quotes and
# automated steps, and the Files list on the right.
# Used by LeadsController#show and ClientsController#show next to ReplyBox,
# which prepares the composer.
module RecordPage
  extend ActiveSupport::Concern

  TIMELINE_PAGE = 50
  UPCOMING_LIMIT = 6

  # One row on the timeline: kind is :message, :note, :event, or :inquiry.
  Entry = Struct.new(:at, :kind, :record)
  # One row under Upcoming: kind is :task, :quote, or :departure.
  Upcoming = Struct.new(:date, :kind, :record)
  # One row under Files: kind is :attachment, :held, or :quote.
  FileRow = Struct.new(:at, :kind, :record, :message)

  private

  def load_record_page(record)
    @record = record
    @page = [ params[:page].to_i, 1 ].max
    @timeline, @older_timeline = timeline_page(record)
    @thread_unread = thread_unread?(record)
    @files = files_for(record)
    @bookings = bookings_for(record)
  end

  # Every message, note, and non-note activity event, newest first, sliced to
  # one page. The lead's original inquiry is the oldest stone on the last page.
  def timeline_page(record)
    limit = @page * TIMELINE_PAGE + 1
    entries = record_messages(record).limit(limit).includes(:template, files_attachments: :blob).map do |message|
      Entry.new(message.sent_at || message.created_at, :message, message)
    end
    entries += record.notes.newest_first.limit(limit).includes(:author).map do |note|
      Entry.new(note.created_at, :note, note)
    end
    entries += record.activity_events.where.not(kind: "note").newest_first.limit(limit).map do |event|
      Entry.new(event.occurred_at, :event, event)
    end
    entries.sort_by! { |entry| [ entry.at || Time.zone.at(0), entry.record.id ] }
    entries.reverse!
    if inquiry?(record)
      entries << Entry.new(record.received_at || record.created_at, :inquiry, record)
    end
    older = entries.size > @page * TIMELINE_PAGE
    @timeline_total = timeline_total(record)
    [ entries.slice((@page - 1) * TIMELINE_PAGE, TIMELINE_PAGE) || [], older ]
  end

  # For the phone Thread tab count: every stone on every page.
  def timeline_total(record)
    record_messages(record).count + record.notes.count +
      record.activity_events.where.not(kind: "note").count + (inquiry?(record) ? 1 : 0)
  end

  def inquiry?(record)
    record.is_a?(Lead) && (record.message.present? || record.received_at.present? ||
      record.source == "website_form" || record.external_ref.to_s.start_with?("website_form:"))
  end

  # The unread mark on the phone Thread tab: the newest message is inbound
  # and still unread, so the client wrote last.
  def thread_unread?(record)
    latest = record_messages(record).first
    latest&.inbound? && latest.unread?
  end

  def record_messages(record)
    Message.for_owner(record).newest_first
  end

  # Attachments from every message on the record plus one row per quote
  # version, newest first. Traveler documents render from @bookings.
  def files_for(record)
    rows = []
    logo_checksums = signature_logo_checksums
    attached_ids = ActiveStorage::Attachment.where(record_type: "Message", name: "files").select(:record_id)
    messages = record_messages(record)
    messages.where(id: attached_ids).or(messages.where("json_array_length(messages.held_attachments) > 0"))
      .select(:id, :sent_at, :created_at, :direction, :from_address, :held_attachments)
      .includes(files_attachments: :blob).find_each do |message|
      at = message.sent_at || message.created_at
      message.files.each do |file|
        next if EmailSignature.signature_logo_blob?(file.blob, checksums: logo_checksums)

        rows << FileRow.new(at, :attachment, file, message)
      end
      Array(message.held_attachments).each { |held| rows << FileRow.new(at, :held, held, message) }
    end
    record_quotes(record).ordered.includes(:lines).each do |quote|
      rows << FileRow.new(quote.sent_at || quote.created_at, :quote, quote, nil)
    end
    rows.sort_by { |row| row.at || Time.zone.at(0) }.reverse
  end

  def record_quotes(record)
    if record.is_a?(Client)
      Quote.where(client: record).or(Quote.where(lead_id: record.converted_leads.select(:id)))
    else
      Quote.where(lead: record)
    end
  end

  def bookings_for(record)
    contact_id = record.try(:perfectbook_contact_id)
    return PerfectBook::Booking.none if contact_id.blank?

    PerfectBook::Booking.where(perfectbook_contact_id: contact_id)
      .order(Arel.sql("start_date IS NULL, start_date ASC"))
  end
end
