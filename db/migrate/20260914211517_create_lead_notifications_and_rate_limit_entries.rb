class CreateLeadNotificationsAndRateLimitEntries < ActiveRecord::Migration[8.1]
  def change
    remove_column :settings, :intake_copy_to, :string, default: "info@sherpaholidays.com", null: false
    add_column :settings, :lead_webhook_url, :string
    reversible do |direction|
      direction.up do
        execute "UPDATE settings SET lead_webhook_url = json_extract(lead_webhooks, '$[0]') WHERE lead_webhooks IS NOT NULL"
      end
    end
    remove_column :settings, :lead_webhooks, :text

    create_table :lead_notifications do |t|
      t.references :lead, null: false, foreign_key: true
      t.string :event, null: false
      t.datetime :available_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :lead_notifications, :available_at, where: "delivered_at IS NULL"

    create_table :lead_rate_limit_entries do |t|
      t.string :key, null: false
      t.datetime :expires_at, null: false
    end
    add_index :lead_rate_limit_entries, :key
    add_index :lead_rate_limit_entries, :expires_at
  end
end
