class MailImportsController < ApplicationController
  def index
    @imports = MailImport.ordered.limit(20)
  end

  def new
    @import = MailImport.new(scope: "all")
  end

  def create
    @import = MailImport.new(import_params)
    @import.status = "draft"
    if @import.save
      redirect_to preview_mail_import_path(@import), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Builds the preview from a live IMAP scan (or an empty set when the
  # mailbox is not configured) and stores the rows for the commit step.
  def preview
    @import = MailImport.find(params[:id])
    choices = preview_choices
    messages = sample_messages(@import)
    rows = Mail::ImportPreview.build(messages, choices: choices).map do |row|
      { "email" => row.email, "count" => row.count, "suggested_kind" => row.suggested_kind,
        "duplicate" => row.duplicate, "duplicate_name" => row.duplicate_name }
    end
    @import.update!(status: "preview", preview_json: { "rows" => rows, "choices" => choices },
      total_messages: rows.sum { |row| row["count"].to_i })
    @rows = rows
  end

  def commit
    @import = MailImport.find(params[:id])
    choices = commit_choices(@import)
    preview = @import.preview_json.is_a?(Hash) ? @import.preview_json : {}
    @import.update!(preview_json: preview.merge("choices" => choices), status: "running",
      processed_messages: 0)
    Mail::ImportJob.perform_later(@import.id)
    redirect_to mail_import_path(@import), notice: "Import started. Progress updates here."
  end

  def show
    @import = MailImport.find(params[:id])
    @rows = @import.preview_rows
  end

  private

  def import_params
    params.require(:mail_import).permit(:scope, :since_date, :months)
  end

  def preview_choices
    sanitize_choices(params[:choices])
  end

  def commit_choices(import)
    normalized = sanitize_choices(params[:choices])
    existing = import.preview_json.is_a?(Hash) ? (import.preview_json["choices"] || {}) : {}
    existing.merge(normalized)
  end

  # Choices arrive as email -> kind with dynamic email keys, so strong
  # params cannot whitelist the keys. Read the pairs without permit! and
  # allow only the four known kinds.
  def sanitize_choices(raw)
    return {} if raw.blank?
    pairs = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw.to_h
    allowed = %w[client organization lead skip]
    normalized = {}
    pairs.each do |email, kind|
      key = email.to_s.strip.downcase
      next if key.blank? || key.length > 320 || !key.include?("@")

      value = kind.to_s
      value = "client" unless allowed.include?(value)
      normalized[key] = value
    end
    normalized
  rescue StandardError
    {}
  end

  def sample_messages(import)
    fetcher = Mail::ImapFetcher.new
    return [] unless fetcher.configured?

    cutoff = import.cutoff_date
    collected = []
    fetcher.fetch_all(since: cutoff ? cutoff.to_time : nil, limit: 2000) do |item|
      collected << { raw: item.raw }
    end
    collected
  rescue Mail::ImapFetcher::NotConfiguredError, Mail::ImapFetcher::ConnectionError
    []
  end
end
