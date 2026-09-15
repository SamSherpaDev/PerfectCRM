class SettingsController < ApplicationController
  def edit
    @settings = Setting.current
    @perfectbook_configured = PerfectBook.configured?
    @perfectbook_last_success = PerfectBook::SyncState.last_success_at
    @perfectbook_last_error = PerfectBook::SyncState.last_error_row
  end

  def update
    @settings = Setting.current
    value = params.dig(:setting, :appearance).to_s
    unless Setting::APPEARANCES.include?(value)
      @settings.errors.add(:appearance, "is not included in the list")
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
end
