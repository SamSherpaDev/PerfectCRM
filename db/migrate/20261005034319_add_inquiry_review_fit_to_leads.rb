class AddInquiryReviewFitToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :owner_fit_at_inquiry, :string
    add_column :leads, :owner_fit_recorded_at, :datetime
    add_column :leads, :owner_fit_recorded_by, :string
  end
end
