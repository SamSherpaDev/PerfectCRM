class CreateChannelSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_snapshots do |t|
      t.string :channel, null: false
      t.datetime :checked_at, null: false
      t.json :open_items, null: false, default: []
      t.integer :review_count
      t.decimal :review_rating, precision: 3, scale: 2
      t.integer :follower_count
      t.timestamps
    end
    add_index :channel_snapshots, [ :channel, :checked_at, :id ]
    add_check_constraint :channel_snapshots,
      "channel IN ('youtube', 'tripadvisor', 'google_business_profile', 'instagram', 'facebook', 'google_ads', 'meta_ads')",
      name: "channel_snapshots_known_channel"
  end
end
