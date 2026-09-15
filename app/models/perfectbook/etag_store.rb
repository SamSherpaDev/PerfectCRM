# ETag cache for PerfectBook conditional requests.
# One row per GET path+query; the client sends it back as If-None-Match
# so unchanged polls answer 304 with no body to parse.
module PerfectBook
  class EtagStore < ApplicationRecord
    validates :key, presence: true, uniqueness: true
    validates :etag, presence: true

    def self.read(key)
      find_by(key: key)&.etag
    end

    def self.write(key, etag)
      return if key.blank? || etag.blank?

      record = find_or_initialize_by(key: key)
      record.etag = etag
      record.save!
      etag
    end
  end
end
