class CreateTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :tags, :name, unique: true

    create_table :taggings do |t|
      t.references :tag, null: false, foreign_key: true
      t.string :taggable_type, null: false
      t.integer :taggable_id, null: false
      t.timestamps
    end
    add_index :taggings, %i[tag_id taggable_type taggable_id],
      unique: true, name: "index_taggings_on_tag_and_taggable"
    add_index :taggings, %i[taggable_type taggable_id]
  end
end
