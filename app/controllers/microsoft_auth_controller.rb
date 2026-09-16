# Completes the Microsoft 365 "Connect mailbox" flow started in Settings.
# Verifies the state round-trip, exchanges the code for tokens via
# Mail::GraphAuth, starts the first sync straight away, and lands back in
# Settings with the result. Approving as the wrong Microsoft account is
# reported by name rather than stored.
class MicrosoftAuthController < ApplicationController
  def callback
    if params[:error].present?
      return redirect_to edit_settings_path,
        alert: "Microsoft did not approve the connection (#{params[:error]}).", status: :see_other
    end
    stored = session.delete(:microsoft_auth_state)
    unless params[:code].present? && params[:state].present? && state_matches?(stored, params[:state])
      return redirect_to edit_settings_path,
        alert: "Mailbox connect was interrupted. Try Connect mailbox again.", status: :see_other
    end

    Mail::GraphAuth.connect!(code: params[:code], redirect_uri: microsoft_callback_url)
    Mail::SyncJob.perform_later
    redirect_to edit_settings_path,
      notice: "Mailbox connected. Ongoing sync starts now; past mail stays for Import history.",
      status: :see_other
  rescue Mail::WrongMailboxError => e
    redirect_to edit_settings_path, alert: e.message, status: :see_other
  rescue Mail::GrantRevokedError
    redirect_to edit_settings_path,
      alert: "Microsoft refused the connection. Try Connect mailbox again.", status: :see_other
  rescue Mail::NotConfiguredError, Mail::ConnectionError
    redirect_to edit_settings_path,
      alert: "Mailbox is unreachable right now. Try Connect mailbox again in a minute.", status: :see_other
  end

  private

  def state_matches?(stored, provided)
    return false if stored.blank? || provided.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(stored.to_s), Digest::SHA256.hexdigest(provided.to_s))
  end
end
