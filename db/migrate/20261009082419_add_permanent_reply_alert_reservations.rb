class AddPermanentReplyAlertReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reply_alert_reservations do |t|
      t.string :provider_message_id, null: false
      t.references :message, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :reply_alert_reservations, :provider_message_id, unique: true
  end
end
