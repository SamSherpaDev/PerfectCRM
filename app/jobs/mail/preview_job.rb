class Mail::PreviewJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(id) { "mail-preview-#{id}" }

  def perform(id, fetcher: nil)
    import = MailImport.find(id)
    return if %w[preview running done].include?(import.status)

    import.update!(status: "previewing", error: nil)
    fetcher ||= Mail::GraphFetcher.new
    progress = import.preview_json || {}
    progress["counts"] ||= {}
    progress["scanned"] ||= 0
    progress["kept"] ||= 0
    # Counting is per provider message id: if the same message is ever
    # yielded twice in one walk, the preview the captain commits against
    # still shows it once.
    counted = Set.new
    fetcher.fetch_history(since: import.cutoff_date&.to_time, cursor: progress["preview_cursor"]) do |item|
      next unless counted.add?(item.provider[:message_id].to_s)

      progress["counts"] ||= {}
      progress["kept"] += 1
      Mail.counterparties(item.parsed).each do |email|
        progress["counts"][email] = progress["counts"].fetch(email, 0) + 1
      end
      progress["scanned"] += 1
      progress["preview_cursor"] = item.cursor
      import.update!(preview_json: progress, total_messages: progress["kept"])
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
