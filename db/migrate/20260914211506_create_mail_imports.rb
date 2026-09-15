class CreateMailImports < ActiveRecord::Migration[8.1]
  def change
    create_table :mail_imports do |t|
      t.string :status, null: false, default: "draft"
      t.string :scope, null: false, default: "all"
      t.date :since_date
      t.integer :months
      t.text :preview_json
      t.integer :total_messages, default: 0, null: false
      t.integer :processed_messages, default: 0, null: false
      t.integer :created_clients, default: 0, null: false
      t.integer :created_organizations, default: 0, null: false
      t.integer :linked_messages, default: 0, null: false
      t.integer :skipped_messages, default: 0, null: false
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
  end
end
