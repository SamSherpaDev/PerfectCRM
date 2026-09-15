class Mail::PreviewJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(id) { "mail-preview-#{id}" }

  def perform(id, fetcher: nil)
    import = MailImport.find(id)
    return if %w[preview running done].include?(import.status)

    import.update!(status: "previewing", error: nil)
    fetcher ||= Mail::ImapFetcher.new
    progress = import.preview_json || {}
    fetcher.fetch_all(since: import.cutoff_date&.to_time, after_uid: progress["preview_uid"],
      uid_validity: progress["preview_validity"], on_mailbox: ->(validity) {
        if progress["preview_validity"] != validity
          progress = { "preview_validity" => validity, "counts" => {}, "scanned" => 0, "kept" => 0 }
          import.update!(preview_json: progress, total_messages: 0)
        end
      }) do |item|
      parsed = Mail::Ingester.parse_raw(item.raw)
      progress["counts"] ||= {}
      if Mail.keeps?(parsed.headers)
        progress["kept"] = progress.fetch("kept", 0) + 1
        Mail.counterparties(parsed).each do |email|
          progress["counts"][email] = progress["counts"].fetch(email, 0) + 1
        end
      end
      progress["scanned"] = progress.fetch("scanned", 0) + 1
      progress["preview_uid"] = item.uid
      progress["preview_validity"] = item.uid_validity
      import.update!(preview_json: progress, total_messages: progress.fetch("kept", 0))
    end
    rows = Mail::ImportPreview.new.build_counts(progress.fetch("counts", {})).map do |row|
      { "email" => row.email, "count" => row.count, "suggested_kind" => row.suggested_kind,
        "duplicate" => row.duplicate, "duplicate_name" => row.duplicate_name }
    end
    import.update!(status: "preview", preview_json: progress.merge("rows" => rows))
  rescue StandardError => e
    import&.update!(status: "preview_failed", error: e.message.to_s.truncate(500))
    raise
  end
end
