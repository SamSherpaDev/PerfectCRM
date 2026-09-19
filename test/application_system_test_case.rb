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

  # Runs an action (select, choose, or click) that submits a full-page POST
  # in the quote builder. When navigation commits before chromedriver
  # answers the action, it can report UnknownError
  # ("Node with given id does not belong to the document"), which Capybara
  # does not retry. The submit may already have executed, so control falls
  # through: the assertion that follows must verify post-navigation state
  # and fail when the submit never landed. Wait for re-rendered state such
  # as the updated description; checked controls or unchanged row counts
  # can match the pre-navigation DOM. Never retry the action itself here;
  # a second submit could duplicate the record.
  def tolerate_submit_navigation
    yield
  rescue Selenium::WebDriver::Error::UnknownError
    nil
  end

  # Re-runs a read-only, navigation-adjacent assertion when the builder's
  # full-page POST commits mid-read (chromedriver reports UnknownError,
  # "Node with given id does not belong to the document", which Capybara
  # does not retry). Retry once for this race: the next navigation is
  # test-driven, so the retried read should see the committed document.
  # A second error propagates. Only wrap reads here; a
  # mutating click retried after a lost response would duplicate the record
  # (see tolerate_submit_navigation).
  def tolerate_navigation_assertion
    yield
  rescue Selenium::WebDriver::Error::UnknownError
    yield
  end
end
