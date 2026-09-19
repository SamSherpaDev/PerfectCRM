class AddArchivedAtToLeads < ActiveRecord::Migration[8.1]
  OLD_EMAIL_WHERE = "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost'"
  NEW_EMAIL_WHERE = "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost' AND archived_at IS NULL"
  OLD_PERFECTBOOK_WHERE = "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost'"
  NEW_PERFECTBOOK_WHERE = "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost' AND archived_at IS NULL"

  def up
    add_column :leads, :archived_at, :datetime unless column_exists?(:leads, :archived_at)
    add_index :leads, :archived_at unless index_exists?(:leads, :archived_at)

    swap_unique_index!(:email, NEW_EMAIL_WHERE)
    swap_unique_index!(:perfectbook_contact_id, NEW_PERFECTBOOK_WHERE)
  end

  def down
    swap_unique_index!(:email, OLD_EMAIL_WHERE)
    swap_unique_index!(:perfectbook_contact_id, OLD_PERFECTBOOK_WHERE)

    if index_exists?(:leads, :archived_at, name: "index_leads_on_archived_at")
      remove_index :leads, name: "index_leads_on_archived_at"
    end
    remove_column :leads, :archived_at if column_exists?(:leads, :archived_at)
  end

  private

  def swap_unique_index!(column, to_where)
    name = "index_leads_on_#{column}"
    current = connection.indexes(:leads).find { |index| index.name == name }
    return if current&.where == to_where

    remove_index :leads, name: name if current
    unless index_exists?(:leads, column, name: name)
      add_index :leads, column, unique: true, where: to_where
    end
  end
end
