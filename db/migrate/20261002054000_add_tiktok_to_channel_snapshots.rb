class AddTiktokToChannelSnapshots < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :channel_snapshots,
      "channel IN ('youtube', 'tripadvisor', 'google_business_profile', 'instagram', 'facebook', 'google_ads', 'meta_ads')",
      name: "channel_snapshots_known_channel"
    add_check_constraint :channel_snapshots,
      "channel IN ('youtube', 'tiktok', 'tripadvisor', 'google_business_profile', 'instagram', 'facebook', 'google_ads', 'meta_ads')",
      name: "channel_snapshots_known_channel"
  end
end
