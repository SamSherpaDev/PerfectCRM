module LeadsHelper
  LEAD_SOURCE_ICONS = {
    "google_ads" => :megaphone,
    "meta_ads" => :megaphone,
    "trade_show" => :people,
    "website_form" => :globe,
    "email" => :mail,
    "referral" => :people,
    "manual" => :pencil
  }.freeze

  def lead_source_icon(source)
    LEAD_SOURCE_ICONS.fetch(source.to_s, :info)
  end

  def lead_source_label(lead)
    parts = [ lead.source.to_s.humanize ]
    parts << lead.campaign_name if lead.campaign_name.present?
    parts.join(" · ")
  end

  def lead_fit_bar_class(band)
    { "strong" => "bar-good", "possible" => "bar-warn", "weak" => "bar-bad" }.fetch(band, "")
  end

  def lead_budget_label(band)
    {
      "discuss" => "To discuss",
      "under_2000" => "Under 2,000 per person",
      "2000_4000" => "2,000-4,000 per person",
      "4000_7000" => "4,000-7,000 per person",
      "7000_plus" => "7,000+ per person"
    }.fetch(band)
  end

  # Bolt for n8n and the website form, robot for Panda AI: the timeline
  # stone always names which machine acted.
  def automation_icon(caller_name)
    caller_name.to_s.downcase.include?("panda") ? :robot : :bolt
  end

  def automation_caller(event)
    event.metadata.is_a?(Hash) ? event.metadata["caller"].to_s : ""
  end
end
