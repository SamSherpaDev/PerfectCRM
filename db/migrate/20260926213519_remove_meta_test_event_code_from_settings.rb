class RemoveMetaTestEventCodeFromSettings < ActiveRecord::Migration[8.1]
  def change
    remove_column :settings, :meta_test_event_code, :string
  end
end
