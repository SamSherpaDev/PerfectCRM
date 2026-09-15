# Last success/error per PerfectBook sync job. The Settings
# "PerfectBook connection" section reads this for its status lines.
module PerfectBook
  class SyncState < ApplicationRecord
    JOBS = %w[catalog contacts bookings].freeze

    validates :job_name, presence: true, uniqueness: true

    def self.for(job_name)
      find_or_create_by!(job_name: job_name.to_s)
    end

    def self.record_success!(job_name)
      state = self.for(job_name)
      state.update!(last_success_at: Time.current, last_error: nil, last_error_at: nil)
      state
    end

    def self.record_error!(job_name, message)
      state = self.for(job_name)
      state.update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
      state
    end

    def self.last_success_at
      where.not(last_success_at: nil).maximum(:last_success_at)
    end

    def self.last_error_row
      where.not(last_error_at: nil).order(last_error_at: :desc).first
    end
  end
end
