class CreatePerfectbookEtagStores < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_etag_stores do |t|
      t.string :key, null: false
      t.string :etag, null: false
      t.timestamps
    end
    add_index :perfectbook_etag_stores, :key, unique: true
  end
end
