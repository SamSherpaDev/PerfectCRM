module InquiryCosts
  # Read-only, website inquiries only. See docs/channel-checks.md for the
  # attribution, exclusion, completeness, and spend accounting rules.
  class Report
    SOURCES = { "google_ads" => "Google Ads", "meta_ads" => "Meta ads", "unknown" => "Unknown source" }.freeze
    MAX_DAYS = 31

    Row = Struct.new(:day, :source, :campaign_key, :campaign, :ad_id, :ad,
      :spend, :inquiries, :excluded, :unassigned, keyword_init: true) do
      def cost_per_inquiry
        return nil if spend.nil? || inquiries.zero? || unassigned.positive?

        spend.transform_values { |amount| Rational(amount, inquiries).round }
      end

      def source_label
        SOURCES.fetch(source, "Other website sources")
      end
    end

    attr_reader :start_date, :end_date

    def initialize(start_date: Date.yesterday - 6, end_date: Date.yesterday)
      @start_date, @end_date = start_date, end_date
      unless start_date <= end_date && (end_date - start_date).to_i < MAX_DAYS &&
          start_date >= Date.current - 2.years && end_date < Date.current
        raise ArgumentError, "Choose up to 31 complete days within the last two years."
      end
    end

    def daily_rows
      build
      @daily_rows
    end

    def campaign_rows
      build
      @campaign_rows
    end

    def ad_rows
      build
      @ad_rows
    end

    def totals
      build
      @totals
    end

    private

    def new_row(day, source, key = nil, campaign = nil, ad_id = nil, ad = nil)
      Row.new(day: day, source: source, campaign_key: key, campaign: campaign,
        ad_id: ad_id, ad: ad, spend: nil, inquiries: 0, excluded: 0, unassigned: 0)
    end

    def build
      return if @daily_rows

      spends = DailyAdSpend.where(spent_on: start_date..end_date).order(:spent_on, :id).to_a
      # The page receives aggregate rows; this query omits contact columns.
      inquiries = website_inquiries.pluck(:received_at, :created_at, :source, :campaign_name, :metadata, :id)
      spam_ids = Tagging.joins(:tag).where(taggable_type: "Lead", tags: { name: Lead::SUSPECTED_SPAM_TAG })
        .where(taggable_id: website_inquiries.select(:id)).pluck(:taggable_id).to_set
      campaign_names = spends.group_by { |spend| [ spend.source, spend.campaign_name ] }
        .transform_values { |entries| entries.map(&:campaign_id).uniq }
      campaigns, ads = {}, {}
      labels = spends.group_by { |spend| [ spend.source, "id:#{spend.campaign_id}" ] }
        .transform_values { |entries| (entries.select { |spend| spend.ad_id.blank? }.last || entries.last).campaign_name }
      ad_labels = {}
      @totals = { inquiries: 0, excluded: 0, unknown_source: 0, unknown_campaign: 0, unknown_ad: 0 }

      spends.each do |spend|
        key = "id:#{spend.campaign_id}"
        row_key = [ spend.spent_on, spend.source, key ]
        campaign = campaigns[row_key] ||= new_row(*row_key)
        row = if spend.ad_id.present?
          ad_labels[[ spend.source, key, spend.ad_id ]] = spend.ad_name
          ads[[ *row_key, spend.ad_id ]] ||= new_row(*row_key, nil, spend.ad_id)
        else
          campaign
        end
        row.spend ||= {}
        row.spend[spend.currency] = spend.amount_minor
      end

      inquiries.each do |received_at, created_at, source, campaign_name, metadata, id|
        day = (received_at || created_at).in_time_zone.to_date
        source, key, name, ad_id = identity(source, campaign_name, metadata, campaign_names)
        labels[[ source, key ]] ||= name
        row_key = [ day, source, key ]
        row = campaigns[row_key] ||= new_row(*row_key)
        spam = spam_ids.include?(id)
        row[spam ? :excluded : :inquiries] += 1
        @totals[spam ? :excluded : :inquiries] += 1
        unless spam
          @totals[:unknown_source] += 1 if source == "unknown"
          if AdSpend::SOURCES.include?(source)
            @totals[:unknown_campaign] += 1 if key.nil?
            @totals[:unknown_ad] += 1 if ad_id.nil?
          end
        end
        if AdSpend::SOURCES.include?(source)
          ad = ads[[ *row_key, ad_id ]] ||= new_row(*row_key, nil, ad_id)
          ad[spam ? :excluded : :inquiries] += 1
        end
      end

      # A supplied campaign or ad needs an exact row for every selected day.
      # Gaps remain unknown; ad detail never substitutes for a campaign total.
      campaign_keys = campaigns.keys.map { |_, source, key| [ source, key ] }
        .select { |source, key| AdSpend::SOURCES.include?(source) && key }.uniq
      ad_keys = ads.keys.map { |_, source, key, ad_id| [ source, key, ad_id ] }.select { |_, _, id| id }.uniq
      (start_date..end_date).each do |day|
        campaign_keys.each { |source, key| campaigns[[ day, source, key ]] ||= new_row(day, source, key) }
        ad_keys.each do |source, key, id|
          campaigns[[ day, source, key ]] ||= new_row(day, source, key)
          ads[[ day, source, key, id ]] ||= new_row(day, source, key, nil, id)
        end
      end

      currencies = spends.group_by { |spend| [ spend.source, "id:#{spend.campaign_id}", spend.ad_id.presence ] }
        .transform_values { |entries| entries.map(&:currency).uniq.sort }
      (campaigns.values + ads.values).each do |row|
        expected = currencies[[ row.source, row.campaign_key, row.ad_id ]]
        row.spend = nil if expected && row.spend&.keys&.sort != expected
      end

      unknown_sources = campaigns.values.select { |row| row.source == "unknown" }.index_by(&:day)
      unknown_campaigns = campaigns.values.select { |row| row.campaign_key.nil? }.index_by { |row| [ row.day, row.source ] }
      unknown_ads = ads.values.select { |row| row.ad_id.nil? }.index_by { |row| [ row.day, row.source, row.campaign_key ] }
      campaigns.each_value do |row|
        row.campaign = labels[[ row.source, row.campaign_key ]]
        if AdSpend::SOURCES.include?(row.source)
          row.unassigned = unknown_sources[row.day]&.inquiries.to_i
          row.unassigned += unknown_campaigns[[ row.day, row.source ]]&.inquiries.to_i if row.campaign_key
        end
      end
      ads.each_value do |row|
        campaign = campaigns.fetch([ row.day, row.source, row.campaign_key ])
        row.campaign = campaign.campaign
        row.ad = ad_labels[[ row.source, row.campaign_key, row.ad_id ]]
        row.unassigned = campaign.unassigned
        row.unassigned += unknown_ads[[ row.day, row.source, row.campaign_key ]]&.inquiries.to_i if row.ad_id
      end
      @campaign_rows = sort(campaigns.values.select { |row| AdSpend::SOURCES.include?(row.source) })
      @ad_rows = sort(ads.values)
      @daily_rows = (start_date..end_date).to_a.reverse.flat_map do |day|
        AdSpend::SOURCES.map do |source|
          entries = campaigns.values.select { |row| row.day == day && row.source == source }
          row = new_row(day, source)
          row.inquiries = entries.sum(&:inquiries)
          row.excluded = entries.sum(&:excluded)
          row.unassigned = unknown_sources[day]&.inquiries.to_i
          # Unknown campaign inquiries have no spend row and make the sum unknown.
          if entries.any? && entries.all?(&:spend)
            row.spend = entries.flat_map { |entry| entry.spend.to_a }.group_by(&:first)
              .transform_values { |amounts| amounts.sum(&:last) }
          end
          row
        end + campaigns.values.select { |row| row.day == day && !AdSpend::SOURCES.include?(row.source) }
      end
    end

    def sort(rows)
      rows.sort_by { |row| [ -row.day.jd, row.source, row.campaign.to_s, row.campaign_key.to_s, row.ad_id.to_s ] }
    end

    def website_inquiries
      tests = Client.where(is_test: true).select(:id)
      test_inquiries = Lead.where(converted_client_id: tests).or(Lead.where(existing_client_id: tests)).select(:id)
      website = Lead.where(capture_channel: "website_form")
        .or(Lead.where(capture_channel: [ nil, "" ]).where("external_ref LIKE ? ESCAPE '\\'", "website\\_form:%"))
        .or(Lead.where(capture_channel: [ nil, "" ], source: "website_form"))
      website.where(is_test: false).where.not(id: test_inquiries)
        .where("COALESCE(received_at, leads.created_at) >= ? AND COALESCE(received_at, leads.created_at) < ?",
          start_date.in_time_zone.beginning_of_day, (end_date + 1).in_time_zone.beginning_of_day)
    end

    def identity(compatibility_source, campaign_name, metadata, names)
      metadata = {} unless metadata.is_a?(Hash)
      acquisition = metadata["acquisition"]
      if acquisition.is_a?(Hash)
        return [ "unknown", nil, nil, nil ] unless Leads::Acquisition.permitted?(acquisition)
        touch = acquisition["last_non_direct_touch"]
        return [ "unknown", nil, nil, nil ] unless Leads::Acquisition.eligible?(touch)
        source = touch["source"].presence || "unknown"
      else
        # Legacy website intake stored its normalized source beside this snapshot.
        touch = metadata["attribution"].is_a?(Hash) ? metadata["attribution"] : {}
        source = AdSpend::SOURCES.include?(compatibility_source) ? compatibility_source : Leads::Acquisition.classify(touch)
      end
      return [ source == "unknown" ? "unknown" : "other", nil, nil, nil ] unless AdSpend::SOURCES.include?(source)

      name = touch["utm_campaign"].to_s.strip.presence
      name ||= campaign_name.to_s.strip.presence unless acquisition.is_a?(Hash)
      id = touch["campaign_id"].to_s.strip.presence
      matches = names[[ source, name ]] || []
      return [ source, nil, nil, touch["ad_id"].to_s.strip.presence ] if id.nil? && matches.size > 1
      id ||= matches.sole if matches.size == 1
      key = id ? "id:#{id}" : ("name:#{name}" if name)
      [ source, key, name, touch["ad_id"].to_s.strip.presence ]
    end
  end
end
