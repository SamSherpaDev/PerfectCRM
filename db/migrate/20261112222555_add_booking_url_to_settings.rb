class AddBookingUrlToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :booking_url, :string, default: "", null: false
  end
end
