class SessionsController < ApplicationController
  skip_before_action :require_sign_in, only: [ :new, :create, :failure ]

  def new
    redirect_to root_path if current_user
  end

  def create
    reset_session
    claims = GoogleIdentity.claims(request.env["omniauth.auth"])
    user = User.find_or_initialize_by(google_sub: claims.fetch("sub"))
    user.update!(email: claims.fetch("email"), name: claims["name"], last_signed_in_at: Time.current)
    session[:user_id] = user.id
    redirect_to root_path
  rescue GoogleIdentity::NotAllowed
    render :not_allowed, status: :forbidden
  rescue GoogleIdentity::Unverified
    render :failure, status: :unprocessable_content
  end

  def destroy
    reset_session
    redirect_to sign_in_path, status: :see_other
  end

  def failure
    render :failure, status: :unprocessable_content
  end
end
