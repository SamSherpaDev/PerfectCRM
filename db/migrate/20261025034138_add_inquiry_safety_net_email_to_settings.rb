# The daily safety net keeps adding missing website inquiries to New and
# listing them on Today; its report email sends only when enabled
# explicitly (README.md, "Mail").
class AddInquirySafetyNetEmailToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :inquiry_safety_net_email, :boolean, default: false, null: false
  end
end
