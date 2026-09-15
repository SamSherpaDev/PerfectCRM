class SettingsController < ApplicationController
  def edit
    @settings = Setting.current.ensure_intake_credentials!
    @perfectbook_configured = PerfectBook.configured?
    @perfectbook_last_success = PerfectBook::SyncState.last_success_at
    @perfectbook_last_error = PerfectBook::SyncState.last_error_row
    @mailbox_address = Mail.mailbox_address
    @mail_sync = MailSyncState.find_by(folder: Mail::FOLDER)
    @imports = MailImport.ordered.limit(5)
    load_automation_log
    # Shown once, right after rotation; never rendered again.
    @fresh_relay_secret = session.delete(:fresh_relay_secret)
    @ai_calls_today = AiCall.today.count
    @ai_cost_today = AiCall.daily_cost_cents
  end

  def update
    @settings = Setting.current
    load_automation_log
    if params.dig(:setting, :lead_webhook_url)
      return update_automations
    end
    setting_params = params[:setting] || {}
    if setting_params.key?(:appearance) || setting_params.key?("appearance")
      update_appearance(setting_params[:appearance] || setting_params["appearance"])
    elsif setting_params.key?(:digest_enabled) || setting_params.key?("digest_enabled")
      raw = setting_params[:digest_enabled].nil? ? setting_params["digest_enabled"] : setting_params[:digest_enabled]
      @settings.update!(digest_enabled: ActiveModel::Type::Boolean.new.cast(raw))
      redirect_to edit_settings_path, notice: "Settings saved.", status: :see_other
    elsif setting_params.key?(:pipeline_digest)
      @settings.update!(pipeline_digest: setting_params[:pipeline_digest] == "1")
      redirect_to edit_settings_path, notice: "Settings saved.", status: :see_other
    elsif @settings.update(sender_params)
      redirect_to edit_settings_path, notice: "Settings saved.", status: :see_other
    else
      @perfectbook_configured = PerfectBook.configured?
      @perfectbook_last_success = PerfectBook::SyncState.last_success_at
      @perfectbook_last_error = PerfectBook::SyncState.last_error_row
      @mailbox_address = Mail.mailbox_address
      @mail_sync = MailSyncState.find_by(folder: Mail::FOLDER)
      @imports = MailImport.ordered.limit(5)
      render :edit, status: :unprocessable_entity
    end
  end

  def rotate_site_key
    Setting.current.ensure_intake_credentials!.rotate_site_key!
    redirect_to edit_settings_path, notice: "Site key rotated. Update the storefront block.", status: :see_other
  end

  def rotate_relay_secret
    secret = Setting.current.ensure_intake_credentials!.rotate_relay_secret!
    session[:fresh_relay_secret] = secret
    redirect_to edit_settings_path,
      notice: "Relay secret rotated. Copy it now: it is shown once.",
      status: :see_other
  end

  # Tests the PerfectBook read API with a cheap one-row read. Never renders
  # or logs the token.
  def perfectbook_test
    PerfectBook::Client.new.test_connection
    redirect_to edit_settings_path, notice: "PerfectBook connection works.", status: :see_other
  rescue PerfectBook::NotConfiguredError
    redirect_to edit_settings_path, alert: "PerfectBook is not configured yet. Add the API token first.", status: :see_other
  rescue PerfectBook::UnauthorizedError
    redirect_to edit_settings_path, alert: "PerfectBook rejected the API token.", status: :see_other
  rescue PerfectBook::RateLimitedError => e
    wait = e.retry_after ? " Try again in #{e.retry_after} seconds." : ""
    redirect_to edit_settings_path, alert: "PerfectBook rate limit reached.#{wait}", status: :see_other
  rescue PerfectBook::Error => e
    redirect_to edit_settings_path, alert: "PerfectBook is unreachable right now.", status: :see_other
  end

  # Mailbox connection: the Gmail address is fixed to MAILBOX_ADDRESS so
  # personal mail can never drift in; only the login + app password are
  # editable. The password is stored encrypted (Rails encrypts).
  def mailbox
    @settings = Setting.current
    login = params.dig(:setting, :mailbox_login).to_s.strip
    password = params.dig(:setting, :mailbox_app_password).to_s
    @settings.mailbox_login = login.presence
    @settings.mailbox_app_password = password.presence || @settings.mailbox_app_password
    if @settings.save
      redirect_to edit_settings_path, notice: "Mailbox saved.", status: :see_other
    else
      load_settings_supporting_data!
      render :edit, status: :unprocessable_entity
    end
  end

  def mailbox_test
    Mail::ImapFetcher.new.test_connection
    redirect_to edit_settings_path, notice: "Mailbox connection works.", status: :see_other
  rescue Mail::ImapFetcher::NotConfiguredError
    redirect_to edit_settings_path, alert: "Add the mailbox login and app password first.", status: :see_other
  rescue Mail::ImapFetcher::ConnectionError
    redirect_to edit_settings_path, alert: "Mailbox is unreachable right now. Check the login and app password.", status: :see_other
  end

  # AI assistance: provider, model, key (stored encrypted), voice guide,
  # kill switch, rate limit, and daily cost cap. Leaving the key blank
  # preserves the saved key. See README "AI assistance".
  def ai
    @settings = Setting.current
    attrs = params.require(:setting).permit(:ai_enabled, :ai_model,
      :ai_base_url, :ai_voice_guide, :ai_daily_cost_cap_cents, :ai_rate_limit_per_minute)
    @settings.assign_attributes(attrs)
    key = params.dig(:setting, :ai_api_key).to_s.strip
    @settings.ai_api_key = key if key.present?
    if @settings.save
      redirect_to edit_settings_path, notice: "AI assistance saved.", status: :see_other
    else
      load_settings_supporting_data!
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load_settings_supporting_data!
    load_automation_log
    @perfectbook_configured = PerfectBook.configured?
    @perfectbook_last_success = PerfectBook::SyncState.last_success_at
    @perfectbook_last_error = PerfectBook::SyncState.last_error_row
    @mailbox_address = Mail.mailbox_address
    @mail_sync = MailSyncState.find_by(folder: Mail::FOLDER)
    @imports = MailImport.ordered.limit(5)
    @ai_calls_today = AiCall.today.count
    @ai_cost_today = AiCall.daily_cost_cents
  end

  def sender_params
    params.require(:setting).permit(:sender_name, :email_signature)
  end

  def update_appearance(value)
    value = value.to_s
    unless Setting::APPEARANCES.include?(value)
      @settings.errors.add(:appearance, "is not included in the list")
      load_settings_supporting_data!
      return respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("appearance-status", "Appearance could not be saved. Choose Paper or Night."), status: :unprocessable_entity
        end
        format.html { render :edit, status: :unprocessable_entity }
      end
    end
    # Appearance applies on its own auto-submitting form (see the Stimulus
    # controller): bypass validations so the choice always persists, with no
    # separate Save step.
    @settings.update_column(:appearance, value)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.update("appearance-status", "Settings saved.") }
      format.html { redirect_to edit_settings_path, notice: "Settings saved.", status: :see_other }
    end
  end

  def load_automation_log
    @automation_events = ActivityEvent.where(kind: "automation").newest_first.limit(50).includes(:subject)
    @webhook_deliveries = LeadWebhookDelivery.newest_first.limit(50).includes(:lead)
    @honeypot_dropped = Rails.cache.read("intake:honeypot:dropped") || 0
  end

  def update_automations
    @settings.lead_webhook_url = params.dig(:setting, :lead_webhook_url).to_s.strip.presence
    if @settings.save
      redirect_to edit_settings_path, notice: "Automations saved.", status: :see_other
    else
      redirect_to edit_settings_path,
        alert: @settings.errors.full_messages.to_sentence,
        status: :see_other
    end
  end
end
