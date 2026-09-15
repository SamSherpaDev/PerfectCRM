class ApplicationController < ActionController::Base
  before_action :require_sign_in
  before_action :set_current_actor
  helper_method :current_user

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = nil
    if session[:user_id]
      user = User.find_by(id: session[:user_id])
      @current_user = user if user && User.allowed_email?(user.email)
      reset_session unless @current_user
    end
    @current_user
  end

  def require_sign_in
    response.headers["Cache-Control"] = "no-store"
    redirect_to sign_in_path unless current_user
  end

  def set_current_actor
    Current.user_email = current_user&.email
  end
end
