class CreateGuideRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :guide_requests do |t|
      t.string :email, null: false
      t.string :edition, null: false
      t.string :source, null: false
      t.references :message, foreign_key: true, index: { unique: true }
      t.datetime :delivery_attempted_at

      t.timestamps
    end
    add_index :guide_requests, [ :email, :edition ], unique: true
  end
end
