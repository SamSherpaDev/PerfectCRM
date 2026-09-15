module ApplicationHelper
  # Status vocabulary shared across the app; unknown values fall back to neutral.
  STATUS_TONES = {
    "active" => :success, "paid" => :success, "posted" => :success, "settled" => :success,
    "closed" => :neutral, "done" => :success, "completed" => :success, "released" => :success,
    "confirmed" => :info, "departed" => :info, "upcoming" => :info, "open" => :brand,
    "sent" => :info, "partially_paid" => :warning,
    "enquiry" => :neutral, "quoted" => :brand, "agreement_sent" => :info,
    "deposit_received" => :info, "operator_confirmed" => :info,
    "balance_received" => :success, "travelling" => :brand,
    "pending" => :warning, "planned" => :neutral, "skipped" => :neutral, "inactive" => :neutral,
    "cancelled" => :danger, "refunded" => :warning, "voided" => :danger, "overdue" => :danger,
    "soft-deleted" => :danger,
    "connected" => :success, "pulling" => :info, "error" => :danger, "disconnected" => :neutral,
    "new" => :info, "chatting" => :neutral, "nudged" => :warning, "lost" => :neutral,
    "won" => :success, "post_trip" => :info, "stage_change" => :info,
    "converted" => :success, "conversion" => :success, "automation" => :info
  }.freeze

  # USD amounts from integer cents: "$1,234.56", "-$12.00".
  def money(minor)
    minor = minor.to_i
    sign = minor.negative? ? "-" : ""
    "#{sign}$#{number_with_delimiter(format('%.2f', minor.abs / 100.0))}"
  end

  # Any supported currency from integer minor units. USD keeps the dollar sign;
  # every other currency is prefixed with its ISO code: "NPR 140,000.00".
  def money_in(minor, currency)
    return money(minor) if currency.blank? || currency == "USD"

    minor = minor.to_i
    sign = minor.negative? ? "-" : ""
    "#{sign}#{currency} #{number_with_delimiter(format('%.2f', minor.abs / 100.0))}"
  end

  def badge(text, tone = :neutral, dot: false)
    content_tag :span, text, class: "badge badge-#{tone}#{' badge-dot' if dot}"
  end

  def status_badge(status, label: nil)
    tone = STATUS_TONES.fetch(status.to_s, :neutral)
    badge(label || status.to_s.humanize.downcase, tone, dot: true)
  end

  # One plain-language line under a card or table title: what it shows and what to do with it.
  def card_caption(text)
    content_tag :p, text, class: "card-caption"
  end

  # Pipeline stage tones (docs/DESIGN.md 2.2): one badge per stage, always with the word.
  STAGE_TONES = {
    "new" => :info, "chatting" => :neutral, "quoted" => :brand,
    "nudged" => :warning, "won" => :success, "post-trip" => :info,
    "lost" => :quiet
  }.freeze

  def stage_badge(stage)
    tone = STAGE_TONES.fetch(stage.to_s, :neutral)
    badge(stage.to_s.humanize.downcase, tone, dot: true)
  end

  # A drawing from the sketch library (shared/_sketches): shared drawings plus
  # the CRM's everest, bridge, pass, cairn, stream and mark-a (docs/DESIGN.md 7).
  SKETCH_VIEWBOXES = { ridge: "0 0 600 150", river: "0 0 720 40", stupa: "0 0 300 150", teahouse: "0 0 300 150",
                       wheel: "0 0 120 150", enso: "0 0 64 64", rule: "0 0 720 6", mark: "0 0 24 24",
                       everest: "0 0 600 150", bridge: "0 0 300 150", pass: "0 0 300 150",
                       cairn: "0 0 300 150", stream: "0 0 40 720", "mark-a": "0 0 24 24" }.freeze

  SKETCH_PRESERVE = { river: "none", rule: "none", ridge: "xMaxYMax meet",
                      everest: "xMaxYMax meet", stream: "none" }.freeze

  def sketch(name, **options)
    name = name.to_s.dasherize.to_sym
    preserve = SKETCH_PRESERVE.fetch(name, "xMidYMid meet")
    css = options.delete(:class) || "sk"
    content_tag(:svg, tag.use(href: "#sk-#{name}"),
      { viewBox: SKETCH_VIEWBOXES.fetch(name), preserveAspectRatio: preserve, class: css, "aria-hidden": true, focusable: false }.merge(options))
  end

  # Thinking orb (Stimulus `orb` controller on a canvas): `composing` while
  # drafting, `shaping` while scoring or triaging. Sizes 20 (inline) or 64
  # (avatar); ochre on Paper, cream on Night, static when reduced motion.
  ORB_LABELS = { "composing" => "Composing…", "shaping" => "Shaping…" }.freeze

  def orb(state, size: 20, label: nil)
    state = ORB_LABELS.key?(state.to_s) ? state.to_s : "composing"
    size = size.to_i == 64 ? 64 : 20
    tag.canvas(role: "img", "aria-label": label || ORB_LABELS.fetch(state),
      class: "orb", data: { controller: "orb", orb_state_value: state, orb_size_value: size, orb_label_value: label })
  end

  # Plain rendered text (merge results) to safe preview HTML: escape, keep
  # line breaks, badge the missing markers.
  def plain_preview(text)
    highlight_missing(simple_format(ERB::Util.html_escape(text.to_s)))
  end

  # Wraps [missing: name] markers in a warning badge inside already-safe HTML.
  def highlight_missing(safe_html)
    safe_html.to_s.gsub(/\[missing: ([\w]+)\]/) do
      content_tag(:span, "Missing: #{Regexp.last_match(1).tr("_", " ")}", class: "badge badge-warning")
    end.html_safe # rubocop:disable Rails/OutputSafety
  end

  def usage_line(template)
    count = template.usage_count
    used = count == 1 ? "Used once" : "Used #{count} times"
    last = template.last_used_at ? " · last used #{time_ago_in_words(template.last_used_at)} ago" : " · never used"
    "#{used}#{last}"
  end

  # Model constants live behind helpers because bare `Template` in a view
  # resolves to ActionView::Template, not the model.
  def template_purpose_options
    ::Template.purposes.keys.map { |key| [ ::Template::PURPOSE_LABELS.fetch(key), key ] }
  end

  def template_purpose_label(key)
    ::Template::PURPOSE_LABELS.fetch(key.to_s)
  end

  # Tab in a `.tabs` nav: icon, sentence-case label, optional count, brush underline when active.
  def tab_link(label, path, icon:, active: false, count: nil)
    link_to path, class: "tab#{' tab-on' if active}", aria: ({ current: "page" } if active) do
      parts = [ render("shared/icon", name: icon, class: "h-4 w-4"), content_tag(:span, label) ]
      parts << content_tag(:span, count, class: "tab-count") unless count.nil?
      safe_join(parts)
    end
  end

  def current_scheme
    return "paper" unless current_user

    Setting.current.appearance.presence || "paper"
  rescue ActiveRecord::StatementInvalid
    "paper"
  end

  def nav_link(label, path, icon:, active: false)
    link_to path, class: "nav-link#{' nav-link-active' if active}", title: label, aria: ({ current: "page" } if active) do
      safe_join([ render("shared/icon", name: icon, class: "nav-icon"), content_tag(:span, label, class: "rail-label") ])
    end
  end

  def date_short(date)
    date&.strftime("%b %-d, %Y")
  end

  # Due phrasing for a follow-up task: overdue reads as a warning.
  def due_label(task)
    if task.overdue?
      content_tag(:span, "Overdue since #{date_short(task.due_on)}", class: "font-medium text-bad")
    elsif task.due_on == Date.current
      "Due today"
    else
      "Due #{date_short(task.due_on)}"
    end
  end

  # Organization websites are user-entered. Only link http(s); otherwise text.
  def external_website_link(url)
    href = url.to_s.strip
    return "—" if href.blank?
    return href unless href.match?(%r{\Ahttps?://[^\s]+\z})

    link_to href, href, class: "link", target: "_blank", rel: "noopener"
  end

  def date_range(from, to)
    "#{date_short(from)} – #{date_short(to)}"
  end

  # Times read 24-hour with the 12-hour equivalent in parentheses: "14:30 (2:30 PM)".
  def time_24_12(value)
    return "—" if value.blank?

    moment = value.is_a?(String) ? Time.zone.parse(value) : value
    "#{moment.strftime('%H:%M')} (#{moment.strftime('%-I:%M %p')})"
  end

  # Deep links into PerfectBook, the system of record for bookings.
  # Contact links are built from the base URL; booking links reuse the
  # absolute deep_link the API returns per booking.
  def perfectbook_contact_url(id)
    PerfectBook.contact_url(id)
  end

  def perfectbook_booking_url(booking)
    booking.deep_link
  end
end
