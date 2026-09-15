class RefineQuoteWorkflow < ActiveRecord::Migration[8.1]
  def change
    add_column :quotes, :sent_by_email, :string
    reversible do |dir|
      dir.up { execute "UPDATE quotes SET status = 'expired' WHERE status = 'declined'" }
    end
    remove_column :quotes, :declined_at, :datetime
    create_table :quote_trip_preferences do |t|
      t.integer :perfectbook_trip_id, null: false
      t.text :included
      t.timestamps
    end
    add_index :quote_trip_preferences, :perfectbook_trip_id, unique: true
  end
end
