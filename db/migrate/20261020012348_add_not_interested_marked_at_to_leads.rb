class AddNotInterestedMarkedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :not_interested_marked_at, :datetime
  end
end
