class AddPhoneRawToClients < ActiveRecord::Migration[8.1]
  def change
    add_column :clients, :phone_raw, :text
  end
end
