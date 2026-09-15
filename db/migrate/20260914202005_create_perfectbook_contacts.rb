class CreatePerfectbookContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_contacts do |t|
      t.integer :perfectbook_id, null: false
      t.string :kind
      t.string :name
      t.string :email
      t.string :phone
      t.string :country
      t.string :state
      t.boolean :archived, null: false, default: false
      t.datetime :pb_created_at
      t.datetime :pb_updated_at
      t.datetime :synced_at, null: false
      t.timestamps
    end
    add_index :perfectbook_contacts, :perfectbook_id, unique: true
    add_index :perfectbook_contacts, :kind
  end
end
