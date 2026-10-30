class ApplicationController < ActionController::Base
  before_action :require_sign_in
  before_action :set_current_actor
  helper_method :current_user, :listed_files

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = nil
    if session[:login_token].present?
      login = LoginSession.includes(:user).for_token(session[:login_token])
      if login && login.expires_at > Time.current && User.allowed_email?(login.user.email)
        login.renew!
        @current_user = login.user
      else
        end_login_session
      end
    elsif session[:user_id]
      # Pre-revocation cookies cannot establish a server-side session.
      reset_session
    end
    @current_user
  end

  def end_login_session
    LoginSession.for_token(session[:login_token])&.destroy!
    reset_session
    @current_user = nil
  end

  def require_sign_in
    response.headers["Cache-Control"] = "no-store"
    redirect_to sign_in_path unless current_user
  end

  def set_current_actor
    Current.user_email = current_user&.email
  end

  # A message's attachments as listed and counted everywhere: the CRM's own
  # signature logo, quoted back on replies, stays stored but is never shown
  # as a file. The logo checksums load once per request.
  def listed_files(message)
    @signature_logo_checksums ||= EmailSignature.logo_checksums
    message.files.reject { |file| EmailSignature.signature_logo_blob?(file.blob, checksums: @signature_logo_checksums) }
  end

  def with_name_change_skips(notice)
    skipped = Current.name_change_skips.to_i
    return notice if skipped.zero?

    "#{notice} #{skipped} linked #{"record".pluralize(skipped)} kept the old name."
  end
end
