class CreateTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :templates do |t|
      t.string :name, null: false
      t.integer :purpose, null: false, default: 8
      t.string :subject, null: false, default: ""
      t.text :body, null: false, default: ""
      t.string :channel, null: false, default: "email"
      t.integer :position, null: false, default: 0
      t.integer :usage_count, null: false, default: 0
      t.datetime :last_used_at
      t.datetime :archived_at

      t.timestamps
    end

    add_index :templates, :purpose
    add_index :templates, :position
    add_index :templates, :archived_at
  end
end
