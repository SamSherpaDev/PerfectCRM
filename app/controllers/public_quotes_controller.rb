# Public tap-to-accept page (/q/:token). No sign-in: the token is the key,
# so it stays unguessable (has_secure_token) and 404s when unknown. Views
# are logged and rate-limited; the link dies after valid_until.
class PublicQuotesController < ApplicationController
  skip_before_action :require_sign_in

  VIEW_LIMIT = 30
  VIEW_WINDOW = 10.minutes

  before_action :find_quote
  before_action :rate_limit_views, only: :show

  def show
    log_view
    @quote.mark_viewed!
  end

  def accept
    if @quote.expired?
      return redirect_to public_quote_path(@quote.accept_token), alert: "This quote has expired. Reply to info@sherpaholidays.com and Sam will refresh it."
    end

    if @quote.accept!
      QuoteMailer.accepted_notice(@quote).deliver_later
      redirect_to public_quote_path(@quote.accept_token), notice: "Accepted - thank you! Sam will be in touch to confirm your booking."
    else
      redirect_to public_quote_path(@quote.accept_token), alert: "This quote can no longer be accepted."
    end
  end

  private

  def find_quote
    @quote = Quote.where.not(sent_at: nil).where.not(status: "draft").includes(:lines, :client, :lead).find_by!(accept_token: params[:token])
  end

  def rate_limit_views
    digest = QuoteView.digest(request.remote_ip)
    recent = @quote.views.where(ip_digest: digest).where("created_at >= ?", VIEW_WINDOW.ago).count
    return if recent < VIEW_LIMIT

    Rails.logger.warn("Quote accept page rate-limited: #{@quote.reference}")
    render plain: "Too many requests. Try again in a few minutes.", status: :too_many_requests
  end

  def log_view
    @quote.views.create!(ip_digest: QuoteView.digest(request.remote_ip))
  end
end
