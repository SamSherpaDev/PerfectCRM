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
      Mail::PreviewJob.perform_later(@import.id)
      redirect_to preview_mail_import_path(@import), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def preview
    @import = MailImport.find(params[:id])
    if request.post? && %w[draft preview_failed].include?(@import.status)
      Mail::PreviewJob.perform_later(@import.id)
      redirect_to preview_mail_import_path(@import), status: :see_other
      return
    end
    @rows = @import.preview_rows
  end

  def commit
    @import = MailImport.find(params[:id])
    @import.with_lock do
      unless %w[preview failed].include?(@import.status)
        return redirect_to mail_import_path(@import), alert: "Wait for a complete preview before importing."
      end
      choices = commit_choices(@import)
      preview = @import.preview_json || {}
      @import.update!(preview_json: preview.merge("choices" => choices), status: "running")
      Mail::ImportJob.perform_later(@import.id)
    end
    redirect_to mail_import_path(@import), notice: "Import started. Progress updates here."
  end

  def show
    @import = MailImport.find(params[:id])
    if %w[draft previewing preview_failed preview].include?(@import.status)
      redirect_to preview_mail_import_path(@import)
      return
    end
    @rows = @import.preview_rows
  end

  private

  def import_params
    params.require(:mail_import).permit(:scope, :since_date, :months)
  end

  def commit_choices(import)
    normalized = sanitize_choices(params[:choices])
    existing = import.preview_json.fetch("choices") { import.preview_rows.to_h { |row| [ row["email"], row["suggested_kind"] ] } }
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
end
