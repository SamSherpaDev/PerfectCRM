class CreateDocumentUploadOrphans < ActiveRecord::Migration[8.1]
  def change
    create_table :document_upload_orphans do |t|
      t.string :key, null: false
      t.string :service_name, null: false
      t.timestamps
    end
    add_index :document_upload_orphans, :key, unique: true
  end
end
