class AddPotentialMarkedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :potential_marked_at, :datetime
  end
end
