class SettingsController < ApplicationController
  def edit
    @settings = Setting.current
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
end
