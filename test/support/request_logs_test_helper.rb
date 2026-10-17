module RequestLogsTestHelper
  private

  def capture_request_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.formatter = Rails.logger.formatter
    logger.level = Logger::INFO
    Rails.logger.broadcast_to(logger)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
