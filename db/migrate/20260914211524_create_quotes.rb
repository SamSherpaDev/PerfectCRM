class CreateQuotes < ActiveRecord::Migration[8.1]
  def change
    create_table :quotes do |t|
      t.references :client, foreign_key: true
      t.references :lead, foreign_key: true
      t.references :parent, foreign_key: { to_table: :quotes }
      t.string :reference, null: false
      t.string :status, null: false, default: "draft"
      t.string :currency, null: false, default: "USD"
      t.integer :version, null: false, default: 1
      t.integer :party_size
      t.string :trip_name
      t.string :departure_label
      t.date :departure_start_on
      t.date :departure_end_on
      t.integer :perfectbook_trip_id
      t.integer :perfectbook_departure_id
      t.text :notes
      t.text :included
      t.integer :deposit_minor, null: false, default: 0
      t.date :balance_due_on
      t.date :valid_until
      t.string :accept_token, null: false
      t.datetime :sent_at
      t.datetime :viewed_at
      t.datetime :accepted_at
      t.datetime :declined_at
      t.integer :view_count, null: false, default: 0
      t.text :intake_payload
      t.timestamps
    end
    add_index :quotes, :reference, unique: true
    add_index :quotes, :accept_token, unique: true
    add_index :quotes, :status
  end
end
