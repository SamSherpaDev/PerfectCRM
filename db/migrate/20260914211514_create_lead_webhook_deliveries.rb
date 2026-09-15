class CreateLeadWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :lead_webhook_deliveries do |t|
      t.references :lead, foreign_key: true
      t.string :event, null: false
      t.string :url, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.integer :http_status
      t.text :error
      t.timestamps
    end
    add_index :lead_webhook_deliveries, :created_at
  end
end
