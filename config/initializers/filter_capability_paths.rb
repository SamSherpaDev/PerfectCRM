# Rails uses filtered_path for both Started lines and controller notifications.
# Redact here without changing the path used for routing or response links.
module FilterCapabilityPaths
  TOKEN_PATH = %r{(/(?:q|%71)/)[^/?\s"'\\]+}i

  def self.redact(message)
    message.to_s.gsub(TOKEN_PATH, '\1[FILTERED]')
  end

  def filtered_path
    FilterCapabilityPaths.redact(super)
  end

  # Routing errors include the raw PATH_INFO in their exception message,
  # bypassing filtered_path. Apply the same redaction at the final log sink.
  module LogFormatter
    def call(severity, time, progname, message)
      super(severity, time, progname, FilterCapabilityPaths.redact(message))
    end
  end
end

ActionDispatch::Request.prepend(FilterCapabilityPaths)

Rails.application.config.after_initialize do
  Rails.logger.formatter.extend(FilterCapabilityPaths::LogFormatter)
end
