# frozen_string_literal: true

# Per-minute guard so a stuck loop or a long thread can never hammer the
# provider. Backed by Rails.cache; the limit lives in Settings.
module Ai
  module RateLimit
    def self.check_and_hit(settings = Setting.current)
      limit = settings.ai_rate_limit_per_minute.to_i
      return true unless limit.positive?

      key = "ai:rate:#{Time.current.strftime('%Y%m%d%H%M')}"
      count = Rails.cache.increment(key, 1, expires_in: 70.seconds)
      count.present? && count <= limit
    end
  end
end
