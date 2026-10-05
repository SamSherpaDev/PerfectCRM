class AddDeliveryStatusToAdConversions < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_conversions, :delivery_status, :string, null: false, default: "not_sent"
    add_column :ad_conversions, :last_skip_reason, :string
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE ad_conversions SET delivery_status = CASE
            WHEN meta_sent_at IS NOT NULL OR meta_status = 'sent' OR google_first_served_at IS NOT NULL OR google_serve_count > 0 THEN 'accepted'
            WHEN meta_status = 'rejected' THEN 'rejected'
            WHEN meta_status IN ('sending', 'uncertain', 'failed') OR (meta_status = 'skipped' AND meta_attempts > 0) THEN 'unknown'
            ELSE 'not_sent' END,
            last_skip_reason = CASE WHEN meta_status = 'skipped' THEN meta_error ELSE NULL END
        SQL
      end
    end
  end
end
