class SettingsController < ApplicationController
  def edit
    @settings = Setting.current.ensure_intake_credentials!
    load_settings_supporting_data!
    # Shown once, right after rotation; never rendered again.
    @fresh_relay_secret = session.delete(:fresh_relay_secret)
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
      load_settings_supporting_data!
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

  # Removes the uploaded signature logo; the signature keeps its words.
  def remove_signature_logo
    Setting.current.signature_logo.purge
    redirect_to edit_settings_path, notice: "Logo removed.", status: :see_other
  end

  # Serves the uploaded signature logo for the Settings preview.
  # (Active Storage routes stay off; attachments serve through controllers.)
  def logo
    setting = Setting.current
    return head :not_found unless EmailSignature.logo_attached?(setting)

    blob = setting.signature_logo.blob
    send_data blob.download, filename: blob.filename.to_s,
      type: blob.content_type, disposition: "inline"
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

  # Mailbox connection: delegated Microsoft 365 OAuth. The mailbox address
  # is fixed to MAILBOX_ADDRESS so personal mail can never drift in; only
  # the Microsoft grant connects it. "Connect mailbox" sends the captain
  # to Microsoft, and /auth/microsoft/callback stores the refresh token
  # encrypted on Setting (see Mail::GraphAuth). The button that reaches
  # here opts out of Turbo: this answers with a cross-origin redirect, and
  # only a native form submission can follow one.
  def mailbox_connect
    state = SecureRandom.hex(24)
    session[:microsoft_auth_state] = state
    redirect_to Mail::GraphAuth.authorization_url(redirect_uri: microsoft_callback_url, state: state),
      allow_other_host: true
  rescue Mail::NotConfiguredError
    redirect_to edit_settings_path,
      alert: "Add MS_GRAPH_CLIENT_ID, MS_GRAPH_CLIENT_SECRET and MS_GRAPH_TENANT_ID to .env.app first.",
      status: :see_other
  end

  def mailbox_test
    Mail::GraphFetcher.new.test_connection
    # A token refresh plus /me just proved the grant works, so a recorded
    # revocation no longer holds.
    settings = Setting.current
    if settings.mailbox_grant_revoked?
      settings.update_columns(mailbox_last_error: nil, mailbox_last_error_at: nil, updated_at: Time.current)
    end
    redirect_to edit_settings_path, notice: "Mailbox connection works.", status: :see_other
  rescue Mail::NotConfiguredError
    redirect_to edit_settings_path, alert: "Connect the mailbox first.", status: :see_other
  rescue Mail::GrantRevokedError => e
    # Record it as sync does, so the card flips to Reconnect needed now
    # instead of at the next sync tick.
    Setting.current.update_columns(mailbox_last_error: e.message.to_s.truncate(500),
      mailbox_last_error_at: Time.current, updated_at: Time.current)
    redirect_to edit_settings_path, alert: "Mailbox access was revoked or expired. Reconnect the mailbox.", status: :see_other
  rescue Mail::ConnectionError
    redirect_to edit_settings_path, alert: "Mailbox is unreachable right now. Try again in a minute.", status: :see_other
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
    @mailbox_error = MailSyncState.recently_errored.first
    @mailbox_notices = MailSyncState.recently_noticed.to_a
    @graph_configured = Mail::GraphAuth.configured?
    @imports = MailImport.ordered.limit(5)
    @ai_calls_today = AiCall.today.count
    @ai_cost_today = AiCall.daily_cost_cents
  end

  def sender_params
    params.require(:setting).permit(:sender_name, :email_signature, :email_signature_html, :signature_logo)
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
