class CreateEmailIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :email_identities do |t|
      t.string :email, null: false
      t.string :linkable_type
      t.integer :linkable_id
      t.boolean :ignored, default: false, null: false
      t.datetime :last_confirmed_at
      t.timestamps
    end
    add_index :email_identities, :email, unique: true
    add_index :email_identities, %i[linkable_type linkable_id]
  end
end
