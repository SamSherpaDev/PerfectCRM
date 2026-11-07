class AddRecontactToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :recontact_marked_at, :datetime
    add_column :leads, :recontact_on, :date
    add_index :leads, :recontact_marked_at
    add_index :leads, :recontact_on
  end
end
