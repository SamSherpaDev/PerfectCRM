class AddInquiryMailAutomation < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :auto_first_reply_enabled, :boolean, default: true, null: false
    add_column :settings, :auto_first_reply_enabled_at, :datetime
    reversible do |direction|
      direction.up do
        execute "UPDATE settings SET auto_first_reply_enabled_at = #{connection.quote(Time.current)}"
      end
    end
    change_column_null :settings, :auto_first_reply_enabled_at, false
    change_column_default :settings, :auto_first_reply_enabled_at, from: nil, to: -> { "CURRENT_TIMESTAMP" }
    create_table :automatic_first_replies do |t|
      t.string :email, null: false
      t.references :lead, foreign_key: { on_delete: :nullify }
      t.references :message, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :automatic_first_replies, :email, unique: true
    add_column :messages, :reply_alert_state, :string
    add_column :messages, :inbound_received_at, :datetime
  end
end
