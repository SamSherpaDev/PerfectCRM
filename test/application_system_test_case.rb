require "test_helper"

Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Turbo navigations under a full parallel load (32 workers locally) can
  # take longer than Capybara's 2s default; wait up to 5s before calling a
  # missing element a failure. CI runs fewer workers and stays well inside it.
  Capybara.default_max_wait_time = 5

  # Cap parallel browser workers: every worker starts its own chromedriver
  # and startups serialize on chromedriver's single global locking port, so
  # a full core-count herd times out binding it (locking port 9514) and
  # every test in the herd errors. CI runners have few cores and keep
  # min(nprocessors) behavior unchanged.
  parallelize(workers: [ Etc.nprocessors, 8 ].min)

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

  # Runs a click that submits a form as a full-page POST (the quote builder
  # submits trip/departure picks and saves that way). When the navigation
  # commits before chromedriver answers the click, it reports UnknownError
  # ("Node with given id does not belong to the document"), which Capybara
  # does not retry. The lost response implies the submit executed, so control
  # falls through: the assertion that follows must verify post-navigation
  # state, and fails loudly when the submit never landed. Never retry the
  # click itself here; a second submit would duplicate the record.
  def tolerate_submit_navigation
    yield
  rescue Selenium::WebDriver::Error::UnknownError
    nil
  end

  # Re-runs a read-only, navigation-adjacent assertion when the builder's
  # full-page POST commits mid-read (chromedriver reports UnknownError,
  # "Node with given id does not belong to the document", which Capybara
  # does not retry). A single retry suffices: the crash implies that commit
  # already happened, and the next navigation is strictly test-driven, so
  # the retried read runs on a stable document. Only wrap reads here; a
  # mutating click retried after a lost response would duplicate the record
  # (see tolerate_submit_navigation).
  def tolerate_navigation_assertion
    yield
  rescue Selenium::WebDriver::Error::UnknownError
    yield
  end
end
