require "test_helper"
require "capybara/selenium/driver"
require "capybara/selenium/nodes/chrome_node"

Capybara.enable_aria_label = true

# Chrome 156+ reports detached DOM nodes during CDP-backed read queries as
# Selenium::WebDriver::Error::UnknownError ("Node with given id does not belong
# to the document") instead of StaleElementReferenceError. Translate read-only
# node and finder inspections to StaleElementReferenceError so Capybara's own
# synchronize and SelectorQuery filter loops retry detached nodes automatically,
# while leaving mutating actions (click, set, send_keys) untouched so
# tolerate_submit_navigation never double-submits a form.
module DetachedNodeStaleGuard
  DETACHED_NODE_MESSAGE = "Node with given id does not belong to the document"

  def self.translate_for(*method_names)
    Module.new do
      method_names.each do |method_name|
        define_method(method_name) do |*args, **kwargs, &block|
          super(*args, **kwargs, &block)
        rescue Selenium::WebDriver::Error::UnknownError => error
          if error.message.include?(DETACHED_NODE_MESSAGE)
            raise Selenium::WebDriver::Error::StaleElementReferenceError, error.message
          end

          raise
        end
      end
    end
  end
end

Capybara::Selenium::ChromeNode.prepend(
  DetachedNodeStaleGuard.translate_for(
    :visible?, :visible_text, :all_text, :value, :style, :tag_name,
    :disabled?, :selected?, :multiple?, :readonly?, :content_editable?,
    :path, :rect, :find_xpath, :find_css
  )
)
Capybara::Selenium::Driver.prepend(
  DetachedNodeStaleGuard.translate_for(:find_xpath, :find_css)
)

# macOS Chrome enforces a 500px minimum outer window width, clamping
# resize_to(390, 844) to 500px. When the window manager clamps the width above
# the requested target, apply CDP Emulation.setDeviceMetricsOverride so 390px
# phone layout tests render at the exact target width, and clear it when
# resizing back to desktop widths.
module NarrowViewportResize
  def resize_to(width, height)
    target_width = Integer(width)
    target_height = Integer(height)
    rect = super(target_width, target_height)
    sync_viewport_override(rect, target_width, target_height)
    rect
  end

  def size=(dimension)
    super.tap do |rect|
      sync_viewport_override(rect, Integer(dimension.width), Integer(dimension.height))
    end
  end

  private

  def sync_viewport_override(rect, target_width, target_height)
    return unless @bridge.respond_to?(:send_command)

    actual_width = rect.is_a?(Hash) ? rect["width"] : (rect.width if rect.respond_to?(:width))
    if actual_width && actual_width > target_width
      @bridge.send_command(
        cmd: "Emulation.setDeviceMetricsOverride",
        params: { width: target_width, height: 0, deviceScaleFactor: 1, mobile: false }
      )
      @viewport_overridden = true
    elsif @viewport_overridden
      @bridge.send_command(cmd: "Emulation.clearDeviceMetricsOverride", params: {})
      @viewport_overridden = false
    end
  end
end

Selenium::WebDriver::Window.prepend(NarrowViewportResize)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  DEFAULT_SCREEN_SIZE = [ 1400, 1400 ].freeze

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

  driven_by :selenium, using: :headless_chrome, screen_size: DEFAULT_SCREEN_SIZE do |option|
    option.args.concat(CONTAINER_CHROME_ARGS) if container_chrome?
    option.args << "mute-audio"
  end

  setup do
    page.current_window.resize_to(*DEFAULT_SCREEN_SIZE)
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
  rescue Selenium::WebDriver::Error::UnknownError, Selenium::WebDriver::Error::StaleElementReferenceError
    yield
  end
end
