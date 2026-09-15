class SettingsController < ApplicationController
  def edit
    @settings = Setting.current.ensure_intake_credentials!
    @perfectbook_configured = PerfectBook.configured?
    @perfectbook_last_success = PerfectBook::SyncState.last_success_at
    @perfectbook_last_error = PerfectBook::SyncState.last_error_row
    load_automation_log
    # Shown once, right after rotation; never rendered again.
    @fresh_relay_secret = session.delete(:fresh_relay_secret)
