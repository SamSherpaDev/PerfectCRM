class AddSenderFieldsToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :sender_name, :string, default: "", null: false
    add_column :settings, :email_signature, :text, default: "", null: false
  end
end
