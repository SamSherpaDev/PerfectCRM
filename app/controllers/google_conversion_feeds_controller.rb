# The conversions CSV that Google Ads pulls on its daily schedule (Goals >
# Uploads > Schedules, source HTTPS). No session: HTTP Basic with the feed
# password from Settings; 404 until a password exists. See README.md,
# "Ad conversions".
class GoogleConversionFeedsController < ActionController::Base
  def show
    settings = Setting.current
    return head :not_found unless settings.google_feed_configured?

    authenticated = authenticate_with_http_basic do |username, password|
      ActiveSupport::SecurityUtils.secure_compare(username.to_s, AdConversions::GoogleFeed::USERNAME) &
        ActiveSupport::SecurityUtils.secure_compare(password.to_s, settings.google_feed_password.to_s)
    end
    return request_http_basic_authentication("SherpaHolidays conversions") unless authenticated

    response.headers["Cache-Control"] = "no-store"
    send_data AdConversions::GoogleFeed.serve!(settings: settings),
      type: "text/csv; charset=utf-8", filename: "sherpaholidays-conversions.csv", disposition: "inline"
  end
end
