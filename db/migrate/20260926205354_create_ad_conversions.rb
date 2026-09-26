class CreateAdConversions < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_conversions do |t|
      t.references :lead, null: false, foreign_key: true
      t.string :event, null: false
      t.string :event_id, null: false
      t.datetime :occurred_at, null: false
      t.integer :value_minor, null: false, default: 0
      t.string :currency, null: false, default: "USD"
      t.boolean :google, null: false, default: false
      t.datetime :google_first_served_at
      t.datetime :google_last_served_at
      t.integer :google_serve_count, null: false, default: 0
      t.string :meta_status, null: false, default: "not_applicable"
      t.integer :meta_attempts, null: false, default: 0
      t.datetime :meta_sent_at
      t.text :meta_error
      t.timestamps
    end
    add_index :ad_conversions, %i[lead_id event], unique: true
    add_index :ad_conversions, :event_id, unique: true
    add_index :ad_conversions, :meta_status
    add_index :ad_conversions, :occurred_at
  end
end
