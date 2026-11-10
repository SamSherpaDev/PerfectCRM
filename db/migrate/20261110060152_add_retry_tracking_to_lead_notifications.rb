class AddRetryTrackingToLeadNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :lead_notifications, :attempts, :integer, default: 0, null: false
    add_column :lead_notifications, :last_enqueued_at, :datetime
    add_column :lead_notifications, :gave_up_at, :datetime
    add_index :lead_notifications, :gave_up_at, where: "gave_up_at IS NOT NULL"
  end
end
