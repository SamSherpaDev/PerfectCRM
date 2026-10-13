class AddAdBreakdownToDailyAdSpends < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_ad_spends, :ad_id, :string, null: false, default: ""
    add_column :daily_ad_spends, :ad_name, :string
    remove_index :daily_ad_spends, %i[spent_on source campaign_id currency],
      unique: true, name: "index_daily_ad_spends_identity"
    add_index :daily_ad_spends, %i[spent_on source campaign_id ad_id currency],
      unique: true, name: "index_daily_ad_spends_identity"
  end
end
