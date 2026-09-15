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

  def lead_fit_bar_class(score)
    return "bar-good" if score.to_i >= 70
    return "bar-warn" if score.to_i >= 40

    "bar-bad"
  end
end
