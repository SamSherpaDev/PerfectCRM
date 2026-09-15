class AddContactCursorToPerfectbookSyncStates < ActiveRecord::Migration[8.1]
  def change
    add_column :perfectbook_sync_states, :contact_cursor, :bigint
  end
end
