class AddBookingSourceReporting < ActiveRecord::Migration[8.1]
  def change
    change_table :perfectbook_bookings do |t|
      t.string :crm_inquiry_ref
      t.datetime :first_received_at
      t.date :first_received_on
      t.string :first_received_precision
      t.integer :receipts_minor
      t.integer :refunds_minor
      t.integer :net_received_minor
      t.integer :traveler_count
      t.datetime :cancelled_at
      t.text :cash_events_json
      t.datetime :unavailable_at
      t.string :binding_issue
    end
    create_table :booking_inquiry_bindings do |t|
      t.integer :perfectbook_id, null: false
      t.references :lead, null: false, foreign_key: true
      t.string :evidence, null: false
      t.string :state, null: false
      t.string :actor, null: false
      t.datetime :linked_at, null: false
      t.timestamps
    end
    add_index :booking_inquiry_bindings, :perfectbook_id, unique: true
    add_column :ad_conversions, :perfectbook_id, :integer
    add_column :ad_conversions, :google_skip_reason, :string
    remove_index :ad_conversions, column: [ :lead_id, :event ]
    add_index :ad_conversions, [ :lead_id, :event ], unique: true, where: "event != 'booked'", name: "index_ad_conversions_lead_outcomes"
    add_index :ad_conversions, :perfectbook_id, unique: true, where: "event = 'booked' AND perfectbook_id IS NOT NULL", name: "index_ad_conversions_booking_outcomes"
    add_column :settings, :meta_terms_accepted, :boolean, null: false, default: false
    add_column :settings, :google_terms_accepted, :boolean, null: false, default: false
    create_table :daily_ad_spends do |t|
      t.date :spent_on, null: false
      t.string :source, null: false
      t.string :campaign_id, null: false
      t.string :campaign_name, null: false
      t.string :currency, null: false, default: "USD"
      t.integer :amount_minor, null: false
      t.timestamps
    end
    add_index :daily_ad_spends, [ :spent_on, :source, :campaign_id, :currency ], unique: true, name: "index_daily_ad_spends_identity"
    create_table :source_backfill_batches do |t|
      t.string :digest, null: false
      t.string :reviewer, null: false
      t.text :reconciliation_json, null: false
      t.timestamps
    end
    add_index :source_backfill_batches, :digest, unique: true
  end
end
