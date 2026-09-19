class AddArchivedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :archived_at, :datetime
    add_index :leads, :archived_at
  end
end
