class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :kind, null: false, default: "other"
      t.string :email
      t.string :phone
      t.string :country
      t.string :website
      t.integer :perfectbook_contact_id
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :organizations, :email, unique: true, where: "email IS NOT NULL AND email != ''"
    add_index :organizations, :perfectbook_contact_id, unique: true, where: "perfectbook_contact_id IS NOT NULL"
    add_index :organizations, :last_activity_at
  end
end
