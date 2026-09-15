class AddDocumentsToPerfectbookBookings < ActiveRecord::Migration[8.1]
  def change
    add_column :perfectbook_bookings, :documents_json, :text, default: "{}", null: false
    add_column :perfectbook_bookings, :missing_count, :integer, default: 0, null: false
    add_column :perfectbook_bookings, :checklist_json, :text, default: "[]", null: false
  end
end
