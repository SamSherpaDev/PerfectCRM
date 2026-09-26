class AddAdConversionSettingsToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :meta_dataset_id, :string
    add_column :settings, :meta_access_token, :text
    add_column :settings, :meta_test_event_code, :string
    add_column :settings, :google_feed_password, :text
    add_column :settings, :google_feed_last_fetched_at, :datetime
    add_column :settings, :google_feed_last_row_count, :integer
    add_column :settings, :ad_booking_value_percent, :integer, null: false, default: 35
    add_column :settings, :ad_export_last_run_at, :datetime
    add_column :settings, :ad_export_last_summary, :text
  end
end
