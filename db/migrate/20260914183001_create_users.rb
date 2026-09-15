class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :google_sub, null: false
      t.string :email, null: false
      t.string :name
      t.datetime :last_signed_in_at
      t.timestamps
    end
    add_index :users, :google_sub, unique: true
  end
end
