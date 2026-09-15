module LeadsHelper
  LEAD_SOURCE_ICONS = {
    "google_ads" => :megaphone,
    "meta_ads" => :megaphone,
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
end
