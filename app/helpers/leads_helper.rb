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

  LEAD_TAB_CAPTIONS = {
    "new" => "Leads you have not sorted yet. Mark Potential, Unsure, Not interested, or spam.",
    "potential" => "Leads you want to follow up with, across all stages. Remove Potential when you no longer need the reminder.",
    "unsure" => "Leads you cannot call yet: voicemail, no reply, maybe spam. Move them on once you know. Three unanswered calls move an ad lead to Re-contact and any other lead to Not interested.",
    "recontact" => "Ad leads who did not answer three call attempts, and leads you set aside for later. Held for a 3-to-6-month re-contact date; due ones show on Today. Never contacted automatically.",
    "not_interested" => "Leads who said they are not interested or did not answer three calls. Kept out of call lists, follow-ups, and automatic emails. Choose Interested again to restore.",
    "missing_source" => "All inquiries without a discovery answer, including converted records. Tests and spam stay out.",
    "archived" => "Archived, spam, and lost leads. Restore an archived lead any time."
  }.freeze

  def lead_tab_title(tab)
    tab.to_s == "recontact" ? "Re-contact" : tab.to_s.humanize
  end

  def lead_tab_caption(tab)
    LEAD_TAB_CAPTIONS.fetch(tab, "Best fit first. Tap a lead to see the full story.")
  end

  def lead_source_icon(source)
    LEAD_SOURCE_ICONS.fetch(source.to_s, :info)
  end

  def lead_source_label(lead)
    parts = [ lead.source.to_s.humanize ]
    ev = lead.metadata.is_a?(Hash) && lead.metadata["attribution"].is_a?(Hash) ? lead.metadata["attribution"] : {}
    campaign = lead.campaign_name.presence || ev["utm_campaign"].presence || ev["campaign_id"].presence
    parts << campaign if campaign.present?
    if ev["campaign_id"].present? && ev["campaign_id"] != campaign
      parts << "campaign #{ev['campaign_id']}"
    end
    if ev["ad_id"].present? && ev["ad_id"] != campaign
      parts << "ad #{ev['ad_id']}"
    end
    if ev["utm_campaign"].present? && ev["utm_campaign"] != campaign && ev["utm_campaign"] != ev["campaign_id"]
      parts << "utm_campaign=#{ev['utm_campaign']}"
    end
    if ev["utm_content"].present? && ev["utm_content"] != ev["ad_id"] && ev["utm_content"] != campaign
      parts << "utm_content=#{ev['utm_content']}"
    end
    if ev["utm_term"].present? && ev["utm_term"] != ev["adset_id"] && ev["utm_term"] != campaign
      parts << "utm_term=#{ev['utm_term']}"
    end
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
