class AllowStrangerGroupMessages < ActiveRecord::Migration[8.1]
  def change
    change_column_null :messages, :conversation_id, true
  end
end
