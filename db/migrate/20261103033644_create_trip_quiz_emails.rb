class CreateTripQuizEmails < ActiveRecord::Migration[8.1]
  # One automatic match email per trip quiz inquiry, committed with the
  # outbound message it queued.
  def change
    create_table :trip_quiz_emails do |t|
      t.references :lead, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.references :message, foreign_key: { on_delete: :nullify }
      t.string :email, null: false
      t.datetime :delivery_attempted_at
      t.timestamps
    end
    add_index :trip_quiz_emails, %i[email created_at]
  end
end
