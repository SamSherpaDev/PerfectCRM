# Resumable history import: re-reads [Gmail]/All Mail from the import's
# cutoff date, respects the same info@ rule as the sync, and records
# progress on the MailImport row so a rerun resumes after an interruption.
class Mail::ImportJob < ApplicationJob
  queue_as :default

  def perform(mail_import_id, fetcher: nil)
    mail_import = ::MailImport.find(mail_import_id)
    mail_import.update!(status: "running", started_at: mail_import.started_at || Time.current, error: nil)
    fetcher ||= Mail::ImapFetcher.new
    cutoff = mail_import.cutoff_date
    total = 0
    processed = mail_import.processed_messages.to_i
    created_clients = mail_import.created_clients.to_i
    created_orgs = mail_import.created_organizations.to_i
    linked = mail_import.linked_messages.to_i
    skipped = mail_import.skipped_messages.to_i

    # Preview choices: email -> { kind:, action: } overrides from the form.
    choices = mail_import.preview_json.is_a?(Hash) ? (mail_import.preview_json["choices"] || {}) : {}

    seen = 0
    fetcher.fetch_all(since: cutoff ? cutoff.to_time : nil) do |item|
      seen += 1
      next if seen <= processed

      parsed = Mail::Ingester.parse_raw(item.raw)
      before_conversations = Conversation.count
      result = Mail::Ingester.ingest(parsed: parsed, gmail: item.gmail)
      total += 1
      if result[:status] == :stored
        linked += 1
        apply_import_choice(result[:conversation], parsed, choices)
      else
        skipped += 1
      end
      processed = seen
      if (seen % 25).zero?
        mail_import.update!(processed_messages: processed, total_messages: [ mail_import.total_messages, seen ].max,
          linked_messages: linked, skipped_messages: skipped)
      end
    end
    mail_import.update!(
      status: "done", processed_messages: seen,
      total_messages: [ mail_import.total_messages, seen ].max,
      linked_messages: linked, skipped_messages: skipped,
      created_clients: created_clients, created_organizations: created_orgs,
      finished_at: Time.current
    )
  rescue StandardError => e
    begin
      ::MailImport.find(mail_import_id).update!(status: "failed", error: e.message.to_s.truncate(500))
    rescue StandardError
      nil
    end
    raise
  end

  private

  # Applies the captain's preview flips: when the preview suggested a kind
  # for an unknown sender, create that record now and link the conversation.
  def apply_import_choice(conversation, parsed, choices)
    return if conversation.nil? || conversation.linked?

    sender = Array(parsed.from_addresses).reject { |value| Mail.mailbox_aliases.include?(value) }.first
    return if sender.blank?

    choice = choices[sender] || choices[sender.downcase]
    kind = choice.is_a?(Hash) ? choice["kind"] : choice
    return if kind.blank? || kind == "skip"

    name = sender.split("@").first.to_s.split(/[._\-+]/).map(&:capitalize).join(" ").presence || sender
    record = case kind.to_s
    when "client"
      ::Client.find_by(email: sender) || ::Client.create!(name: name, email: sender, source: "email")
    when "organization"
      ::Organization.find_by(email: sender) || ::Organization.create!(name: name, email: sender, kind: "other")
    when "lead"
      ::Lead.find_by(email: sender) || ::Lead.create!(name: name, email: sender, source: "email")
    end
    return if record.nil?

    conversation.update!(linkable: record)
    ::EmailIdentity.remember!(sender, linkable: record)
  end
end
