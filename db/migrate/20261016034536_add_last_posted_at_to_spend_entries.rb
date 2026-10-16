class AddLastPostedAtToSpendEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_ad_spends, :last_posted_at, :datetime
    add_column :ad_spends, :last_posted_at, :datetime
  end
end
