class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.string :notable_type, null: false
      t.integer :notable_id, null: false
      t.text :body, null: false
      t.references :author, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :notes, %i[notable_type notable_id]
  end
end
