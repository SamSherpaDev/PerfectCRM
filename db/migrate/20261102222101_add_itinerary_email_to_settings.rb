class AddItineraryEmailToSettings < ActiveRecord::Migration[8.1]
  # The automatic "Your Nepal itinerary" email ships switched off until the
  # owner approves its wording. The enable time stamps each switch-on so
  # earlier inquiries never receive a late email.
  def change
    add_column :settings, :itinerary_email_enabled, :boolean, default: false, null: false
    add_column :settings, :itinerary_email_enabled_at, :datetime
  end
end
