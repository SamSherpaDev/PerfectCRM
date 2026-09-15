require "test_helper"

Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Chromedriver refuses to start as root or inside minimal containers without
  # these flags (see the release-readiness audit: ECONNREFUSED in sandbox).
  CONTAINER_CHROME_ARGS = %w[no-sandbox disable-dev-shm-usage].freeze

  def self.container_chrome?
    Process.uid.zero? ||
      ENV["CI"].present? ||
      ENV["CONTAINER"].present? ||
      File.exist?("/.dockerenv") ||
      File.exist?("/run/.containerenv")
  end

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |option|
    option.args.concat(CONTAINER_CHROME_ARGS) if container_chrome?
  end
end
