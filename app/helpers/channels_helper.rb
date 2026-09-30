module ChannelsHelper
  def channel_money(value)
    value.nil? ? "Not available" : money(value)
  end

  def channel_reviews(snapshot)
    return "Not checked" if snapshot&.review_count.nil?

    count = number_with_delimiter(snapshot.review_count)
    return count if snapshot.review_rating.nil?

    "#{count} (#{number_with_precision(snapshot.review_rating, precision: 2, strip_insignificant_zeros: true)}/5)"
  end
end
