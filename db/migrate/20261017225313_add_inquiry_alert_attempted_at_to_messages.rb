class AddInquiryAlertAttemptedAtToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :inquiry_alert_attempted_at, :datetime
    add_index :messages, "COALESCE(inbound_received_at, sent_at, created_at)",
      where: "direction = 'in'", name: "index_messages_on_inquiry_received_at"
  end
end
