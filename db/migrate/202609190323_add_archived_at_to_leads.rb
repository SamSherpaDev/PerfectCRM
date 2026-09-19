class AddArchivedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :archived_at, :datetime
    add_index :leads, :archived_at

    remove_index :leads, :email, unique: true,
      where: "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost'"
    add_index :leads, :email, unique: true,
      where: "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost' AND archived_at IS NULL"
    remove_index :leads, :perfectbook_contact_id, unique: true,
      where: "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost'"
    add_index :leads, :perfectbook_contact_id, unique: true,
      where: "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost' AND archived_at IS NULL"
  end
end
