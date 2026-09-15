class AddPipelineFieldsToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :lost_reason, :string
    add_column :leads, :lost_note, :text
    add_column :leads, :expected_value_minor, :integer
    add_column :leads, :last_touch_at, :datetime
    add_column :leads, :stage_changed_at, :datetime
    add_column :leads, :trip_interest, :string
    add_index :leads, :last_touch_at
  end
end
