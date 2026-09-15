class CreateClients < ActiveRecord::Migration[8.1]
  def change
    create_table :clients do |t|
      t.string :name, null: false
      t.string :email
      t.string :phone
      t.string :country
      t.string :state
      t.string :kind, null: false, default: "individual"
      t.string :source
      t.references :referred_by_organization, foreign_key: { to_table: :organizations }
      t.integer :perfectbook_contact_id
      t.datetime :archived_at
      t.integer :notes_count, null: false, default: 0
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :clients, :email, unique: true, where: "email IS NOT NULL AND email != ''"
    add_index :clients, :perfectbook_contact_id, unique: true, where: "perfectbook_contact_id IS NOT NULL"
    add_index :clients, :archived_at
    add_index :clients, :last_activity_at
  end
end
