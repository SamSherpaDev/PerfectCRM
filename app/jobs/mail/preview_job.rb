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
    progress["kept"] ||= 0
    tally = Mail::HistoryTally.new(cursor: progress["preview_cursor"], seen: progress["counted"])
    fetcher.fetch_history(since: import.cutoff_date&.to_time, cursor: progress["preview_cursor"]) do |item|
      next unless tally.count?(item)

      progress["kept"] += 1
      Mail.counterparties(item.parsed).each do |email|
        progress["counts"][email] = progress["counts"].fetch(email, 0) + 1
      end
      progress["preview_cursor"] = tally.cursor
      progress["counted"] = tally.seen
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
