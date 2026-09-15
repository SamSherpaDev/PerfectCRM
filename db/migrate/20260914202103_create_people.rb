class CreatePeople < ActiveRecord::Migration[8.1]
  def change
    create_table :people do |t|
      t.references :client, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email
      t.string :phone
      t.string :role
      t.timestamps
    end
    add_index :people, :email, unique: true, where: "email IS NOT NULL AND email != ''"
  end
end
