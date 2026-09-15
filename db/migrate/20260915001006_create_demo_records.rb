class CreateDemoRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_records do |t|
      t.string :record_type, null: false
      t.bigint :record_id, null: false
    end
    add_index :demo_records, [ :record_type, :record_id ], unique: true
  end
end
