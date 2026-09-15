class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.string :subject_type, null: false
      t.integer :subject_id, null: false
      t.string :title, null: false
      t.string :kind, null: false, default: "follow_up"
      t.date :due_on, null: false
      t.datetime :due_at
      t.datetime :done_at
      t.date :snoozed_until
      t.string :created_by, null: false, default: "captain"
      t.references :template, foreign_key: true
      t.text :notes
      t.string :idempotency_key

      t.timestamps
    end

    add_index :tasks, %i[subject_type subject_id]
    add_index :tasks, :due_on
    add_index :tasks, :done_at
    add_index :tasks, :idempotency_key, unique: true,
      where: "idempotency_key IS NOT NULL AND idempotency_key != ''"
  end
end
