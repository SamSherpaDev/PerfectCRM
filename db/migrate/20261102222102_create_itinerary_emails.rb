class CreateItineraryEmails < ActiveRecord::Migration[8.1]
  # One automatic itinerary email per designer inquiry, committed with the
  # outbound message it queued.
  def change
    create_table :itinerary_emails do |t|
      t.references :lead, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.references :message, foreign_key: { on_delete: :nullify }
      t.string :email, null: false
      t.datetime :delivery_attempted_at
      t.timestamps
    end
    add_index :itinerary_emails, %i[email created_at]
  end
end
