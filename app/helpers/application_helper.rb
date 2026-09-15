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
    "connected" => :success, "pulling" => :info, "error" => :danger, "disconnected" => :neutral
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

  # A drawing from the sketch library (shared/_sketches): :ridge, :river, :stupa, :teahouse, :wheel, :enso, :rule.
  SKETCH_VIEWBOXES = { ridge: "0 0 600 150", river: "0 0 720 40", stupa: "0 0 300 150", teahouse: "0 0 300 150",
                       wheel: "0 0 120 150", enso: "0 0 64 64", rule: "0 0 720 6", mark: "0 0 24 24" }.freeze

  def sketch(name, **options)
    name = name.to_sym
    preserve = %i[river rule].include?(name) ? "none" : (name == :ridge ? "xMaxYMax meet" : "xMidYMid meet")
    css = options.delete(:class) || "sk"
    content_tag(:svg, tag.use(href: "#sk-#{name}"),
      { viewBox: SKETCH_VIEWBOXES.fetch(name), preserveAspectRatio: preserve, class: css, "aria-hidden": true, focusable: false }.merge(options))
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

  def date_range(from, to)
    "#{date_short(from)} – #{date_short(to)}"
  end

  # Times read 24-hour with the 12-hour equivalent in parentheses: "14:30 (2:30 PM)".
  def time_24_12(value)
    return "—" if value.blank?

    moment = value.is_a?(String) ? Time.zone.parse(value) : value
    "#{moment.strftime('%H:%M')} (#{moment.strftime('%-I:%M %p')})"
  end
end
