class CreateActivityEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_events do |t|
      t.string :subject_type, null: false
      t.integer :subject_id, null: false
      t.string :kind, null: false
      t.string :summary, null: false
      t.datetime :occurred_at, null: false
      t.text :metadata
      t.timestamps
    end
    add_index :activity_events, %i[subject_type subject_id]
    add_index :activity_events, :occurred_at
  end
end
