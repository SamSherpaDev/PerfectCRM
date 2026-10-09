class AddDeliveryAttemptToAutomaticFirstReplies < ActiveRecord::Migration[8.1]
  def change
    add_column :automatic_first_replies, :delivery_attempted_at, :datetime
  end
end
