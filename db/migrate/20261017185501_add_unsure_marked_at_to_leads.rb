class AddUnsureMarkedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :unsure_marked_at, :datetime
  end
end
