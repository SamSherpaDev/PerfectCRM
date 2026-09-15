class AddAutomationColumnsToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :site_key, :string
    add_column :settings, :site_key_version, :integer, null: false, default: 1
    add_column :settings, :site_key_last_used_at, :datetime
    add_column :settings, :relay_secret, :text
    add_column :settings, :relay_secret_version, :integer, null: false, default: 1
    add_column :settings, :relay_last_used_at, :datetime
    add_column :settings, :intake_copy_to, :string, null: false, default: "info@sherpaholidays.com"
    add_column :settings, :lead_webhooks, :text
    add_column :settings, :intake_last_received_at, :datetime
    add_index :settings, :site_key, unique: true, where: "site_key IS NOT NULL AND site_key != ''"
  end
end
